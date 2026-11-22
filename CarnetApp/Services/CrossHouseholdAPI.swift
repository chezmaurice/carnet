import Foundation

/// Giving an entry to someone in another household, and inviting a friend
/// as a guest — every network call of it in one place, so the shapes are
/// easy to follow if the server's change.
/// Design: maurice/specs/cross-household-share.md (sections A–D).
///
/// The device signed into both households is the courier: the entry is read
/// whole from the household on screen (A), shown, then written whole into the
/// other (B) with B's session. No server ever talks to another.
enum CrossHouseholdAPI {

    /// A household of this device, as a request goes out to it: its address
    /// and a member's session there.
    struct Target: Hashable {
        let serverURL: String
        let token: String
    }

    /// The household on screen, as the active member.
    static var current: Target? {
        guard let token = CarnetAPI.authToken, !CarnetAPI.baseURL.isEmpty else { return nil }
        return Target(serverURL: CarnetAPI.baseURL, token: token)
    }

    // MARK: - Paths (the spec's /api/garden is mounted at /api/v1/garden)

    private static func gardenEntry(_ c: String, _ l: String, _ s: String, _ suffix: String) -> String {
        let slug = s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
        return "/api/v1/garden/entries/\(c)/\(l)/\(slug)\(suffix)"
    }
    private static let importPath = "/api/v1/garden/entries/import"
    private static func conversationExportPath(_ id: String) -> String { "/api/conversations/\(id)/export" }
    private static let usersPath = "/api/users"
    private static let guestInvitePath = "/api/me/guest-invite"

    // MARK: - Errors

    /// What can go wrong, each said in the app's language by the sheet.
    enum Failure: Error {
        /// B already holds this entry (same canonical URL / ISBN): where it is.
        case exists(collection: String, locale: String, slug: String)
        /// The person chosen can no longer be shared with in B.
        case unreachable
        /// B does not answer (no network, the server down).
        case offline
        /// The session in B was refused: it has been forgotten on the device.
        case sessionEnded
        /// B's server does not know the route yet.
        case unsupported
        /// 413: what was ticked is more than B takes in one gift.
        case tooLarge
        /// 403: the member may not do this here (a guest inviting, sharing
        /// with someone who is not their contact). The server's code, if any.
        case forbidden(String?)
        /// The server refused, and said why.
        case refused(String)
        case other(String)
    }

    // MARK: - Request helpers

    private static func request(_ target: Target, _ path: String, method: String = "GET",
                                json body: Any? = nil, timeout: TimeInterval = 20) throws -> URLRequest {
        guard let url = URL(string: target.serverURL + path) else { throw Failure.other("Bad address") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.setValue("Bearer \(target.token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    /// Runs a request; a 2xx answers its body, anything else a `Failure`.
    /// `CarnetAPI.fetch` reports a 401, so the refused session is forgotten.
    private static func run(_ request: URLRequest) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await CarnetAPI.fetch(request)
        } catch let error as URLError where error.code != .cancelled {
            throw Failure.offline
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.offline }
        if (200...299).contains(http.statusCode) { return (data, http.statusCode) }
        throw failure(status: http.statusCode, data: data)
    }

    private static func failure(status: Int, data: Data) -> Failure {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = obj?["error"] as? String
        switch status {
        case 401: return .sessionEnded
        case 409 where code == "exists":
            if let c = obj?["collection"] as? String, let l = obj?["locale"] as? String, let s = obj?["slug"] as? String {
                return .exists(collection: c, locale: l, slug: s)
            }
            return .refused(code ?? "exists")
        case 403: return .forbidden(code)
        case 413: return .tooLarge
        case 404 where code == "Unknown member": return .unreachable
        case 404 where code == nil: return .unsupported
        case 502, 503, 504: return .offline
        default:
            return code.map { .refused($0) } ?? .other(String(data: data, encoding: .utf8) ?? "HTTP \(status)")
        }
    }

    // MARK: - The other household's people

    /// GET /api/users on another household, with that household's session:
    /// the people the member can reach there (a guest gets their contacts only).
    static func roster(_ target: Target) async throws -> [CarnetAPI.Member] {
        let (data, _) = try await run(try request(target, usersPath, timeout: 12))
        return try JSONDecoder().decode([CarnetAPI.Member].self, from: data)
    }

    // MARK: - Export (household A)

    /// GET …/entries/:c/:l/:s/export — the entry, element by element.
    static func export(_ target: Target, collection: String, locale: String, slug: String) async throws -> EntryExport {
        let (data, _) = try await run(try request(target, gardenEntry(collection, locale, slug, "/export"), timeout: 30))
        return try JSONDecoder().decode(EntryExport.self, from: data)
    }

    /// GET /api/conversations/:id/export — a conversation whole; refused
    /// unless the member is its only human participant.
    static func conversation(_ target: Target, id: String) async throws -> ConversationExport {
        let (data, _) = try await run(try request(target, conversationExportPath(id), timeout: 30))
        return try JSONDecoder().decode(ConversationExport.self, from: data)
    }

    // MARK: - Import (household B)

    struct Imported: Decodable {
        let collection: String
        let locale: String
        let slug: String
        var ref: String { "\(collection)/\(locale)/\(slug)" }
    }

    /// POST /api/v1/garden/entries/import on B — writes the fiche in the
    /// member's notes there and shares it with `shareWith`.
    static func importEntry(_ target: Target, _ payload: ImportPayload) async throws -> Imported {
        let (data, _) = try await run(try request(target, importPath, method: "POST",
                                                  json: payload.json, timeout: 120))
        return try JSONDecoder().decode(Imported.self, from: data)
    }

    // MARK: - Guest invite (section A)

    /// What POST /api/me/guest-invite answers: the code, the link the QR
    /// carries, when it lapses. Same shape as a device code, plus the link.
    struct GuestInvite: Decodable {
        let code: String
        let link: String?
        let expires_at: String
    }

    /// GET /api/me/guest-invites/:code — `pending`, `used` or `expired`;
    /// nil when the server cannot be reached or does not know the code.
    static func guestInviteState(_ code: String) async -> String? {
        guard let target = current,
              let path = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let request = try? request(target, "\(guestInvitePath)s/\(path)"),
              let (data, _) = try? await run(request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["state"] as? String
    }

    /// A single-use invitation (seven days) that makes a guest whose only
    /// contact is the member — on the household on screen. 403 `not_allowed`
    /// for a guest, or a child the admin has not allowed.
    static func guestInvite() async throws -> GuestInvite {
        guard let target = current else { throw Failure.sessionEnded }
        let (data, _) = try await run(try request(target, guestInvitePath, method: "POST", json: [String: Any]()))
        return try JSONDecoder().decode(GuestInvite.self, from: data)
    }
}

// MARK: - Shapes

/// Any JSON, kept as it came so what is read from A goes to B untouched.
enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    /// For JSONSerialization.
    var any: Any {
        switch self {
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .object(let v): return v.mapValues(\.any)
        case .array(let v): return v.map(\.any)
        case .null: return NSNull()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var strings: [String] {
        if case .array(let a) = self { return a.compactMap(\.string) }
        return string.map { [$0] } ?? []
    }
}

/// GET …/export (spec B).
struct EntryExport: Decodable {
    struct Fiche: Decodable {
        let prose: String?
        let notes: [Note]
    }
    struct Note: Decodable, Identifiable, Hashable {
        let id: String
        let date: String?
        let author: String?
        let text: String
        let quote: String?
        let page: JSONValue?
        /// The note as it came, to send back as is.
        let raw: JSONValue

        enum CodingKeys: String, CodingKey { case id, date, author, text, quote, page }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            date = try c.decodeIfPresent(String.self, forKey: .date)
            author = try c.decodeIfPresent(String.self, forKey: .author)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            quote = try c.decodeIfPresent(String.self, forKey: .quote)
            page = try c.decodeIfPresent(JSONValue.self, forKey: .page)
            raw = try JSONValue(from: decoder)
        }
        var pageLabel: String? {
            switch page {
            case .string(let s): return s
            case .number(let n): return String(Int(n))
            default: return nil
            }
        }
    }
    struct Highlight: Decodable, Identifiable, Hashable {
        let id: String
        let text: String
        let chapter: String?
        let note: String?
        let raw: JSONValue

        enum CodingKeys: String, CodingKey { case id, text, chapter, note }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Ids may come as numbers (SQLite rows).
            if let s = try? c.decode(String.self, forKey: .id) { id = s }
            else { id = String(try c.decode(Int.self, forKey: .id)) }
            text = try c.decode(String.self, forKey: .text)
            chapter = try c.decodeIfPresent(String.self, forKey: .chapter)
            note = try c.decodeIfPresent(String.self, forKey: .note)
            raw = try JSONValue(from: decoder)
        }
    }
    struct Card: Decodable {
        let body: String
        let status: String
        let url: String?
        var isDraft: Bool { status != "published" }
    }
    struct Conversation: Decodable, Identifiable, Hashable {
        let id: String
        let title: String?
        let date: String?
        let message_count: Int?
        let summary: String?
        let shareable: Bool
        let reason: String?
    }

    /// `{ collection, locale, slug, title, kind, author, cover?, meta… }`, kept whole.
    let entry: JSONValue
    /// `{ kind: "article", text, styles, image? }` (image as a data: URI) or `{ kind: "book", calibre }`.
    let source: JSONValue?
    let fiche: Fiche?
    let highlights: [Highlight]?
    let card: Card?
    let conversations: [Conversation]?

    var title: String { entry["title"]?.string ?? "" }
    var kind: String? { entry["kind"]?.string }
    var author: String? {
        let a = entry["author"]?.strings ?? []
        return a.isEmpty ? nil : a.joined(separator: ", ")
    }
    var sourceKind: String? { source?["kind"]?.string }
}

/// GET /api/conversations/:id/export (spec B).
struct ConversationExport: Decodable, Hashable {
    struct Message: Decodable, Hashable {
        let role: String
        let author: String?
        let text: String
        let data: JSONValue?
        var isMaurice: Bool { role == "assistant" }
    }
    let title: String?
    let date: String?
    let messages: [Message]
    let raw: JSONValue

    enum CodingKeys: String, CodingKey { case title, date, messages }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        messages = try c.decode([Message].self, forKey: .messages)
        raw = try JSONValue(from: decoder)
    }
}

/// POST /api/v1/garden/entries/import (spec C). Only what was ticked is in it.
struct ImportPayload {
    var entry: JSONValue
    var source: JSONValue?
    var prose: String?
    var notes: [JSONValue] = []
    var highlights: [JSONValue] = []
    var card: EntryExport.Card?
    /// A conversation sent whole carries its messages; one sent as its
    /// summary carries only that (B writes it as a dated note).
    var conversations: [(meta: EntryExport.Conversation, whole: ConversationExport?)] = []
    var shareWith: String?
    var fromHousehold: String

    var json: [String: Any] {
        var body: [String: Any] = ["entry": entry.any, "from_household": fromHousehold]
        if let source { body["source"] = source.any }
        if let prose { body["prose"] = prose }
        if !notes.isEmpty { body["notes"] = notes.map(\.any) }
        if !highlights.isEmpty { body["highlights"] = highlights.map(\.any) }
        if let card {
            var c: [String: Any] = ["body": card.body, "status": card.status]
            if let url = card.url { c["url"] = url }
            body["card"] = c
        }
        if !conversations.isEmpty {
            body["conversations"] = conversations.map { item -> [String: Any] in
                var c: [String: Any] = ["id": item.meta.id, "mode": item.whole == nil ? "summary" : "whole"]
                if let t = item.whole?.title ?? item.meta.title { c["title"] = t }
                if let d = item.whole?.date ?? item.meta.date { c["date"] = d }
                if let s = item.meta.summary { c["summary"] = s }
                if let whole = item.whole, case .object(let o) = whole.raw, let m = o["messages"] {
                    c["messages"] = m.any
                }
                return c
            }
        }
        if let shareWith { body["share_with"] = shareWith }
        return body
    }
}
