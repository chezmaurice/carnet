import Foundation
import Security
import ImageIO
import LinkPresentation
import UniformTypeIdentifiers

/// Shared API client for Carnet — used by both the main app and the Share Extension.
/// Reads the base URL from the shared App Group UserDefaults.
final class CarnetAPI {
    static let appGroupID = "group.eu.chezmaurice.carnet.app"

    /// The paired server URL. Empty until the user pairs a device — there is no
    /// hardcoded host; the address is always configured by the user (see the
    /// pairing screen / Settings), mirroring Maurice's app.
    static var baseURL: String {
        get {
            if let identity { return identity.serverURL }
            let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
            let own = defaults.string(forKey: "apiBaseURL") ?? ""
            // An extension with no session of Carnet's own goes where the
            // session shared with the Maurice app is (SharedSession).
            if let shared = borrowedSession { return shared.serverURL }
            return own
        }
        set {
            let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
            defaults.set(newValue, forKey: "apiBaseURL")
        }
    }

    // MARK: - Auth

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroupID) ?? .standard }

    /// The active household member's session token (shared with the Share
    /// Extension through the Keychain's app-group access group, so it posts as
    /// whoever is signed in).
    static var authToken: String? {
        if let identity { return identity.token }
        return ownToken ?? borrowedSession?.token
    }

    /// The session Carnet itself keeps: the active member's token, if any.
    private static var ownToken: String? {
        guard let active = defaults.string(forKey: "carnet.activeMemberId") else { return nil }
        return TokenVault.get("carnet.token.\(active)")
    }

    /// Whether Carnet's own store holds a session (and not one borrowed from
    /// the pairings shared with the Maurice app).
    static var hasOwnSession: Bool { ownToken != nil }

    /// In an extension, when Carnet's own store holds no session: the one the
    /// Maurice app and Carnet share (SharedSession) — Carnet installed and not
    /// opened yet, the member already signed in to Maurice. Never in the app,
    /// which folds the shared pairings into its own store and decides by that.
    private static let inExtension = Bundle.main.bundlePath.hasSuffix(".appex")
    private static var borrowedSession: SharedSession.Session? {
        guard inExtension, ownToken == nil else { return nil }
        return SharedSession.read()
    }

    /// The signed-in member of the current household (the flat mirror kept by
    /// CarnetSession). What the on-device caches are kept under.
    static var activeMemberId: String? {
        defaults.string(forKey: "carnet.activeMemberId") ?? borrowedSession?.memberId
    }

    /// Who a request goes out as, when it is not the active member: an offline
    /// capture flushed later goes to the household and under the member it
    /// was made by (SyncService). Read by `baseURL` and `authToken`.
    struct Identity: Sendable {
        let serverURL: String
        let token: String
    }
    @TaskLocal static var identity: Identity?

    /// Every API request goes through here. A 401 to a request that carried a
    /// token means the session was revoked or the member removed — sessions
    /// never expire — and is reported (`.carnetSessionRejected`) so the app
    /// forgets the token. Sign-in routes are left out: a wrong PIN is a 401
    /// too, and the active member's token rides along on them.
    static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse { note(http, for: request) }
        return (data, response)
    }

    static func note(_ http: HTTPURLResponse, for request: URLRequest) {
        guard http.statusCode == 401,
              request.url?.path.hasPrefix("/api/auth/") != true,
              let auth = request.value(forHTTPHeaderField: "Authorization"),
              auth.hasPrefix("Bearer ") else { return }
        NotificationCenter.default.post(name: .carnetSessionRejected, object: nil,
                                        userInfo: ["token": String(auth.dropFirst("Bearer ".count))])
    }

    /// Attach the active member's bearer token to a request, if we have one.
    private static func authed(_ request: URLRequest) -> URLRequest {
        guard let token = authToken else { return request }
        var r = request
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// Attach an explicit bearer token (used during the picker flow, before the
    /// new member becomes the active one).
    private static func authed(_ request: URLRequest, token: String?) -> URLRequest {
        guard let token else { return authed(request) }
        var r = request
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// A GET request to `url` carrying the active member's bearer token.
    /// For code that fetches directly instead of via the methods below
    /// (the cover loader) — it must authenticate too.
    static func authorizedRequest(url: URL) -> URLRequest {
        authed(URLRequest(url: url))
    }

    struct Member: Codable, Identifiable, Hashable {
        let id: String
        let display_name: String
        let avatar_color: String
        let has_pin: Bool
        let role: String?
        /// Sent by the server, but absent from members kept on the device
        /// before it was read — fetch `me(token:)` when it matters.
        var username: String? = nil
        /// The member's picture: a path on the household's server
        /// (`/api/avatars/<file>`, served open) or a full address. Absent for
        /// a member who has none — the coloured initial stands in.
        var avatar_url: String? = nil
    }

    struct LoginResponse: Codable {
        let user_id: String
        let token: String
    }

    struct SetupResponse: Codable {
        let user: Member
        let token: String
    }

    struct HealthResponse: Codable {
        let status: String
        let setup_complete: Bool?
        /// The name the household gives itself, its colour and icon — what
        /// the member switcher and the other-household sections show.
        var household: String? = nil
        var household_color: String? = nil
        var household_icon: String? = nil
        /// The household's public key, pinned once (see HouseholdMove).
        var identity_key: String? = nil
    }

    /// GET /api/health — connectivity check + first-run state when pairing.
    static func health() async throws -> HealthResponse {
        let url = URL(string: "\(baseURL)/api/health")!
        let (data, response) = try await fetch(authed(URLRequest(url: url)))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError("Server not reachable")
        }
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }

    /// GET <server>/api/health — whether a household answers at an address
    /// not paired yet (the welcome screen probes before pairing).
    static func health(at server: String) async throws -> HealthResponse {
        guard let url = URL(string: "\(server)/api/health") else { throw APIError.serverError("") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError("Server not reachable")
        }
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }

    /// POST /api/auth/setup — first-run: create the admin account.
    static func setup(username: String, password: String, displayName: String) async throws -> SetupResponse {
        let url = URL(string: "\(baseURL)/api/auth/setup")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username, "password": password, "display_name": displayName,
        ])
        let (data, response) = try await fetch(authed(request))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError(errorMessage(data))
        }
        return try JSONDecoder().decode(SetupResponse.self, from: data)
    }

    /// POST /api/auth/login — admin (username+password) or member (user_id+PIN).
    static func login(username: String? = nil, password: String? = nil,
                      userID: String? = nil, pin: String? = nil) async throws -> LoginResponse {
        let url = URL(string: "\(baseURL)/api/auth/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [:]
        if let username { payload["username"] = username }
        if let password { payload["password"] = password }
        if let userID { payload["user_id"] = userID }
        if let pin { payload["pin"] = pin }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await fetch(authed(request))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError(errorMessage(data))
        }
        return try JSONDecoder().decode(LoginResponse.self, from: data)
    }

    /// The answer to an enrolment. An open invitation (someone not yet a
    /// member) first answers `needs_profile` with the household's name only;
    /// sent again with a name and a colour, it answers with the session.
    struct EnrollResponse: Codable {
        let user_id: String?
        let token: String?
        let role: String?
        let needs_pin: Bool?
        let needs_profile: Bool?
        let household: String?
    }

    /// POST /api/auth/enroll — redeem an invite code on a fresh device: a
    /// session for that member with no admin password involved. Members are
    /// then asked to set a PIN (`needs_pin`); guests are not. `displayName`
    /// (≤ 40 characters) and `avatarColor` answer an open invitation's
    /// `needs_profile`.
    static func enroll(code: String, displayName: String? = nil, avatarColor: String? = nil) async throws -> EnrollResponse {
        let url = URL(string: "\(baseURL)/api/auth/enroll")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["code": code]
        if let displayName { body["display_name"] = displayName }
        if let avatarColor { body["avatar_color"] = avatarColor }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError(errorMessage(data))
        }
        return try JSONDecoder().decode(EnrollResponse.self, from: data)
    }

    /// POST /api/users/me/mcp-token `{rotate:false}` — the active member's
    /// `maur_` API token, the one a signed-in web link carries. The same token
    /// comes back each time; nothing is revoked.
    static func mcpToken() async throws -> String {
        var request = URLRequest(url: URL(string: "\(baseURL)/api/users/me/mcp-token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["rotate": false])
        let (data, response) = try await fetch(authed(request))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["rawToken"] as? String else {
            throw APIError.serverError(errorMessage(data))
        }
        return token
    }

    /// POST /api/auth/set-pin — the signed-in member sets (or changes) their PIN.
    static func setPin(_ pin: String, token: String) async throws {
        let url = URL(string: "\(baseURL)/api/auth/set-pin")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["pin": pin])
        let (data, response) = try await fetch(authed(request, token: token))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError(errorMessage(data))
        }
    }

    /// GET /api/users/me — the member behind a token.
    static func me(token: String) async throws -> Member {
        let url = URL(string: "\(baseURL)/api/users/me")!
        let (data, response) = try await fetch(authed(URLRequest(url: url), token: token))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError(errorMessage(data))
        }
        return try JSONDecoder().decode(Member.self, from: data)
    }

    /// A code for another device of the signed-in member's, and when it lapses.
    struct DeviceCode: Codable, Identifiable {
        let code: String
        let expires_at: String
        var id: String { code }
    }

    /// POST /api/me/device-code — a fresh code that signs this same member in
    /// on another device (« Add a device »), shown as a QR.
    static func deviceCode() async throws -> DeviceCode {
        var request = URLRequest(url: URL(string: "\(baseURL)/api/me/device-code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await fetch(authed(request))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError(errorMessage(data))
        }
        return try JSONDecoder().decode(DeviceCode.self, from: data)
    }

    /// GET /api/me/device-code/:code — `pending`, `used` or `expired`; nil
    /// when the server cannot be reached.
    static func deviceCodeState(_ code: String) async -> String? {
        guard let path = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/api/me/device-code/\(path)"),
              let (data, response) = try? await fetch(authed(URLRequest(url: url))),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["state"] as? String
    }

    /// GET /api/users/me/preferences → `locale`: the language the member
    /// chose in Maurice, nil when they follow the device. Throws when the
    /// server could not say, so a known choice is not forgotten offline.
    static func chosenLocale(token: String? = nil) async throws -> String? {
        let url = URL(string: "\(baseURL)/api/users/me/preferences")!
        let (data, response) = try await fetch(authed(URLRequest(url: url), token: token))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError(errorMessage(data))
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["locale"] as? String
    }

    /// GET /api/users — household roster. Pass the token of any signed-in
    /// member (so it works before that member is set active).
    static func listMembers(token: String? = nil) async throws -> [Member] {
        let url = URL(string: "\(baseURL)/api/users")!
        let (data, response) = try await fetch(authed(URLRequest(url: url), token: token))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError(errorMessage(data))
        }
        return try JSONDecoder().decode([Member].self, from: data)
    }

    /// POST /api/me/erase with scope `account` — everything the household keeps
    /// of the active member is erased, then the account and all its sessions.
    /// The server wants the username typed again and the password or PIN.
    static func deleteAccount(confirm: String, secret: String) async throws {
        let url = URL(string: "\(baseURL)/api/me/erase")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // An erasure rewrites the night's snapshots too: give it the time.
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "scope": "account", "confirm": confirm, "password": secret, "pin": secret,
        ])
        let (data, response) = try await fetch(authed(request))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = errorMessage(data)
            let messages = [
                "confirm_mismatch": "The username does not match.",
                "bad_password": "Wrong password.",
                "bad_pin": "Wrong PIN.",
                "last_admin": "You are this household’s only administrator and other people live here: name another administrator first.",
                "too_many_attempts": "Too many attempts. Try again in a quarter of an hour.",
            ]
            throw APIError.serverError(messages[code] ?? code)
        }
    }

    /// Extract a server `{ "error": "..." }` message, falling back to raw body.
    private static func errorMessage(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = obj["error"] as? String {
            return msg
        }
        return String(data: data, encoding: .utf8) ?? "Request failed"
    }

    // MARK: - Articles

    /// A saved article, as the garden returns it. Everything past the identity
    /// is optional: a page may carry no byline, no subtitle, no publication
    /// date, and the summary only exists once it has been generated.
    struct SavedArticle: Codable {
        let slug: String
        let title: String
        let locale: String?
        let url: String?
        let saved_at: String?
        /// True when this URL was already in the garden — the save carried the
        /// new comment onto the existing fiche rather than making a second one.
        let duplicate: Bool?
        /// Saved as a bookmark: the site refused the server and no rendered DOM
        /// reached it, so only the URL and the note were kept.
        let needs_capture: Bool?
        /// A bookmark this save filled in.
        let completed: Bool?
        let subtitle: String?
        let author: String?
        let publication: String?
        let published_at: String?
        let image: String?
        let excerpt: String?
        let summary: String?
        let comment: String?
        let tags: [String]?
        let word_count: Int?
        let fiche_path: String?
        let fiche_web_path: String?
        /// The domain the household filed it under, if any, and the member's
        /// domains to choose from instead (none on a server before 8 November
        /// 2026, or for a member without domains).
        let domain: DomainChoice?
        let domain_choices: [DomainChoice]?
    }

    /// One of the member's domains, as an article is filed under it.
    struct DomainChoice: Codable, Hashable, Identifiable {
        let id: String
        let name: String
        let icon: String?
    }

    /// PUT /api/v1/garden/articles/:slug/domain — file the article under one
    /// of the member's domains, or (nil) under none, for good. Answers with
    /// where it now is.
    static func setArticleDomain(slug: String, locale: String?, domainId: String?) async throws -> DomainChoice? {
        guard let path = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/api/v1/garden/articles/\(path)/domain") else {
            throw APIError.serverError("bad slug")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["domain_id": domainId ?? NSNull()]
        if let locale { body["locale"] = locale }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await fetch(authed(request))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError(errorMessage(data))
        }
        struct Filed: Decodable { let domain: DomainChoice? }
        return try JSONDecoder().decode(Filed.self, from: data).domain
    }

    /// Save an article to the member's garden as a fiche.
    ///
    /// Posts to `/api/v1/garden/articles`, which writes the markdown into the
    /// signed-in member's garden. The older `/api/v1/articles/scrape` still
    /// answers (it now delegates here) but returns a trimmed shape.
    static func saveArticle(
        url: String,
        comment: String? = nil,
        tags: [String]? = nil,
        locale: String = "fr",
        sourceClient: String = "ios-share",
        html: String? = nil,
        title: String? = nil,
        selection: String? = nil
    ) async throws -> SavedArticle {
        let endpoint = URL(string: "\(baseURL)/api/v1/garden/articles")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = ["url": url, "locale": locale, "source_client": sourceClient]
        if let tags, !tags.isEmpty { payload["tags"] = tags }
        if let comment, !comment.isEmpty { payload["comment"] = comment }
        // The DOM Safari rendered. Present, the server parses it instead of
        // fetching the URL — the only way past a paywall or a bot check.
        if let html, !html.isEmpty { payload["html"] = html }
        if let title, !title.isEmpty { payload["title"] = title }
        if let selection, !selection.isEmpty { payload["selection"] = selection }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await fetch(authed(request))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw APIError.serverError(msg)
        }
        return try JSONDecoder().decode(SavedArticle.self, from: data)
    }

    /// PUT /garden/entries/:collection/:locale/:slug/cover — the entry's cover,
    /// brought by this device (see `LinkCover`). Answers with the entry as it
    /// now reads, undecoded: the app and the extension want different halves.
    @discardableResult
    static func setCover(collection: String, locale: String, slug: String, jpeg: Data) async throws -> Data {
        let s = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        var request = URLRequest(url: URL(string: "\(baseURL)/api/v1/garden/entries/\(collection)/\(locale)/\(s)/cover")!)
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpeg
        let (data, response) = try await fetch(authed(request))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError(String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// Whether this URL is already in the garden, and the entry if so.
    struct ArticleLookup: Codable {
        let saved: Bool
        let article: SavedArticle?
    }

    static func lookupArticle(url: String) async throws -> ArticleLookup {
        var components = URLComponents(string: "\(baseURL)/api/v1/garden/articles/lookup")!
        components.queryItems = [URLQueryItem(name: "url", value: url)]
        let (data, response) = try await fetch(authed(URLRequest(url: components.url!)))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw APIError.serverError(msg)
        }
        return try JSONDecoder().decode(ArticleLookup.self, from: data)
    }

    // MARK: - Calibre

    struct CalibreAddResult: Codable, Sendable {
        let ok: Bool
        let bookId: Int?
        let filename: String?
        let output: String?
        /// A hosted household answers with the book it already holds.
        let duplicate: Bool?

        /// The library already held the book: Calibre added nothing (a home
        /// library says so in its output, a hosted one with `duplicate`).
        var alreadyThere: Bool {
            duplicate == true || (bookId == nil && (output ?? "").localizedCaseInsensitiveContains("already exist"))
        }
    }

    /// The household's library could not be reached: the book is sent again.
    struct LibraryUnavailable: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A file the household's library takes: an EPUB or a PDF.
    static func isLibraryBook(_ filename: String) -> Bool {
        let f = filename.lowercased()
        return f.hasSuffix(".epub") || f.hasSuffix(".pdf")
    }

    static func addBookToCalibre(data fileData: Data, filename: String) async throws -> CalibreAddResult {
        let url = URL(string: "\(baseURL)/api/v1/calibre/add")!
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let mimeType = filename.lowercased().hasSuffix(".epub") ? "application/epub+zip" : "application/pdf"

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")

        request.httpBody = body
        // A book of tens of megabytes, then `calibredb add` on the server.
        request.timeoutInterval = 120

        let (data, response) = try await fetch(authed(request))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let raw = (obj?["error"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            let msg = raw.isEmpty ? "HTTP \(status)" : raw
            // The library did not answer (a hosted household's Calibre-Web):
            // worth sending again later, unlike a refusal.
            if status == 503 { throw LibraryUnavailable(message: msg) }
            throw APIError.serverError(msg)
        }
        return try JSONDecoder().decode(CalibreAddResult.self, from: data)
    }

    // MARK: - Errors

    enum APIError: LocalizedError {
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .serverError(let msg): return msg
            }
        }
    }
}

// MARK: - Data helper

extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}


// MARK: - A page's own picture, read on the device

/// What a page says of itself for sharing: its title and its picture.
///
/// The server reads these when it can fetch the page. Many sites refuse it —
/// anything that is not a browser gets a 403, or an empty shell whose content
/// arrives by script — and from any app but Safari a share carries only an
/// address, so the article is saved bare. The system's link preview loads the
/// page in a real web engine, on this device and its connection, and hands
/// back exactly these two things. It is what draws the previews in Messages.
enum LinkCover {
    struct Found { let title: String?; let jpeg: Data? }

    /// The longest side of what is sent: a cover, not a poster.
    private static let maxSide = 1200

    @MainActor
    static func fetch(_ url: URL, timeout: TimeInterval = 20) async -> Found {
        let provider = LPMetadataProvider()
        provider.timeout = timeout
        guard let meta = try? await provider.startFetchingMetadata(for: url) else { return Found(title: nil, jpeg: nil) }
        let title = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let image = meta.imageProvider else { return Found(title: title, jpeg: nil) }
        let data: Data? = await withCheckedContinuation { done in
            _ = image.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in done.resume(returning: data) }
        }
        return Found(title: title, jpeg: data.flatMap(jpeg(from:)))
    }

    /// Scaled down and re-encoded through ImageIO, which never holds the full
    /// bitmap: a share extension has little memory to its name.
    private static func jpeg(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

extension Notification.Name {
    /// A member's token was answered 401 (`userInfo["token"]`).
    static let carnetSessionRejected = Notification.Name("carnet.sessionRejected")
}

// MARK: - Token vault

/// Session tokens live in the Keychain, in the app group's access group so the
/// share extension reads them too, one generic-password item per token named
/// by the key the App Group's UserDefaults held it under, in plain text, until
/// 21 October 2026. Readable after the first unlock.
enum TokenVault {
    private static let service = "eu.chezmaurice.carnet.tokens"

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key,
         kSecAttrAccessGroup as String: CarnetAPI.appGroupID]
    }

    /// The token under `key`. A copy still in UserDefaults is read too: the
    /// share extension can run before the app has moved the tokens over.
    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data, let token = String(data: data, encoding: .utf8) {
            return token
        }
        return CarnetAPI.defaults.string(forKey: key)
    }

    @discardableResult
    static func set(_ value: String, _ key: String) -> Bool {
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            print("[keychain] could not store \(key): \(status)")
            return false
        }
        CarnetAPI.defaults.removeObject(forKey: key)
        return true
    }

    static func remove(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
        CarnetAPI.defaults.removeObject(forKey: key)
    }

    /// Run at the app's launch: every token still in the App Group's
    /// UserDefaults moves to the Keychain; `set` erases the plain-text copy
    /// once the Keychain holds it.
    static func migrateFromDefaults() {
        for (key, value) in CarnetAPI.defaults.dictionaryRepresentation() where key.hasPrefix("carnet.token.") {
            if let token = value as? String { set(token, key) }
        }
    }
}
