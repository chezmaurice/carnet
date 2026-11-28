import Foundation

/// Sessions this device gave up — a member signed out, a household was
/// forgotten — that the household's server has not yet been told to close.
///
/// Erasing a token here does not end the session there: until the server is
/// told (`POST /api/auth/logout`, which closes the session of the token it is
/// sent with), whoever holds a copy of the token is still signed in. So a
/// session given up is written down first, then closed; if the server cannot
/// be reached, it stays written down and is closed when the network is back
/// (`flush`, from `SyncService` and when the app comes to the foreground).
///
/// The list lives in the Keychain, as the tokens do: an entry is a token
/// until the server has closed it.
final class SessionClosures {
    struct Pending: Codable, Equatable {
        let server: String
        let token: String
        let since: Date
    }

    /// What the server answered to a closure.
    enum Outcome: Equatable {
        /// Closed now (2xx), or already closed or unknown there (401).
        case closed
        /// No answer, or an answer that says nothing about the session: ask again.
        case retry
    }

    /// A session nobody uses ends on the server by itself after this long;
    /// an entry older than that has nothing left to close.
    static let lifetime: TimeInterval = 90 * 24 * 3600

    static let shared = SessionClosures()

    private let load: () -> [Pending]
    private let save: ([Pending]) -> Void
    private let send: (Pending) async -> Outcome
    private let now: () -> Date
    private let lock = NSLock()
    private var flushing = false

    init(load: @escaping () -> [Pending] = SessionClosures.loadFromVault,
         save: @escaping ([Pending]) -> Void = SessionClosures.saveToVault,
         send: @escaping (Pending) async -> Outcome = SessionClosures.post,
         now: @escaping () -> Date = Date.init) {
        self.load = load
        self.save = save
        self.send = send
        self.now = now
    }

    var pending: [Pending] { lock.withLock { load() } }

    /// Give a session up: written down before this returns — the caller erases
    /// the token next — then closed on the server in the background.
    func close(server: String, token: String) {
        guard !server.isEmpty, !token.isEmpty else { return }
        lock.withLock {
            var list = load()
            guard !list.contains(where: { $0.server == server && $0.token == token }) else { return }
            list.append(Pending(server: server, token: token, since: now()))
            save(list)
        }
        Task { await flush() }
    }

    /// Close on their servers the sessions still written down. One pass at a
    /// time; a session that could not be closed stays for the next pass.
    func flush() async {
        let list: [Pending]? = lock.withLock {
            guard !flushing else { return nil }
            flushing = true
            return load()
        }
        guard let list else { return }
        var done: [Pending] = []
        for entry in list {
            if now().timeIntervalSince(entry.since) > Self.lifetime {
                done.append(entry)
            } else if await send(entry) == .closed {
                done.append(entry)
            }
        }
        lock.withLock {
            // Read again: a session may have been given up during the pass.
            if !done.isEmpty { save(load().filter { !done.contains($0) }) }
            flushing = false
        }
    }

    // MARK: - The server

    /// `POST /api/auth/logout` with the session's own token. Not through
    /// `CarnetAPI.fetch`: a 401 here is the expected answer for a session
    /// already closed, not a session to report as refused.
    static func post(_ entry: Pending) async -> Outcome {
        guard let url = URL(string: "\(entry.server)/api/auth/logout") else { return .closed }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(entry.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .retry }
        return outcome(status: status)
    }

    static func outcome(status: Int) -> Outcome {
        (200...299).contains(status) || status == 401 ? .closed : .retry
    }

    // MARK: - The Keychain

    private static let vaultKey = "carnet.pending-logouts"

    static func loadFromVault() -> [Pending] {
        guard let json = TokenVault.get(vaultKey),
              let list = try? JSONDecoder().decode([Pending].self, from: Data(json.utf8)) else { return [] }
        return list
    }

    static func saveToVault(_ list: [Pending]) {
        guard !list.isEmpty, let data = try? JSONEncoder().encode(list),
              let json = String(data: data, encoding: .utf8) else {
            TokenVault.remove(vaultKey)
            return
        }
        TokenVault.set(json, vaultKey)
    }
}
