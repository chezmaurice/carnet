import Foundation

/// A way into a household: its address and a code, invitation or device code
/// alike. One link serves Maurice and Carnet, and every other way in reads
/// back to it:
///
///   - `https://<household>/join?code=<CODE>` — the QR code, the shared link,
///     a universal link (the household's own landing page works without the app);
///   - `carnet://join?server=<origin>&code=<CODE>` — the landing page's
///     « Open in Carnet » button (same shape as `maurice://join`).
struct Invitation: Equatable {
    let server: String
    let code: String

    init(server: String, code: String) {
        self.server = server
        self.code = code
    }

    init?(_ raw: String) {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = { (name: String) in parts.queryItems?.first { $0.name == name }?.value }
        guard let code = query("code").flatMap(Invitation.normalizedCode) else { return nil }
        switch url.scheme?.lowercased() {
        case "carnet", "maurice":
            guard url.host == "join", let server = query("server"),
                  let normal = EntryInput.normalizedAddress(server) else { return nil }
            self.init(server: normal, code: code)
        case "https", "http":
            guard parts.path == "/join", let host = parts.host else { return nil }
            let port = parts.port.map { ":\($0)" } ?? ""
            self.init(server: "\(url.scheme!.lowercased())://\(host)\(port)", code: code)
        default:
            return nil
        }
    }

    /// The link a QR code carries: the household's landing page.
    var link: String {
        var parts = URLComponents(string: server + "/join")
        parts?.queryItems = [URLQueryItem(name: "code", value: code)]
        return parts?.string ?? server + "/join?code=" + code
    }

    /// `XXXXXXXX` or `XXXX-XXXX`, any case → `XXXX-XXXX`. Nil for anything else.
    static func normalizedCode(_ raw: String) -> String? {
        let letters = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard letters.count == 8,
              typed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              typed.filter({ $0 == "-" }).count <= 1 else { return nil }
        return "\(letters.prefix(4))-\(letters.suffix(4))"
    }
}

/// What the one field of the welcome screen was given: a link (address and
/// code, all that is needed), a code alone (the household's address is asked
/// next — nothing resolves a code to a household, on purpose), or an address
/// alone (pair, then « Who's here? »).
enum EntryInput: Equatable {
    case invitation(Invitation)
    case code(String)
    case address(String)

    init?(_ raw: String) {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        if let invitation = Invitation(typed) {
            self = .invitation(invitation)
        } else if let code = Invitation.normalizedCode(typed) {
            self = .code(code)
        } else if let address = EntryInput.normalizedAddress(typed) {
            self = .address(address)
        } else {
            return nil
        }
    }

    /// `monfoyer.chezmaurice.eu`, with or without scheme or trailing path →
    /// `https://monfoyer.chezmaurice.eu`. A typed `http://` is kept (a home
    /// server on the local network). Nil when there is no host to speak of.
    static func normalizedAddress(_ raw: String) -> String? {
        var typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !typed.contains(" ") else { return nil }
        if !typed.contains("://") { typed = "https://" + typed }
        guard let parts = URLComponents(string: typed),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parts.host, host.contains(".") || host == "localhost" else { return nil }
        let port = parts.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host.lowercased())\(port)"
    }
}
