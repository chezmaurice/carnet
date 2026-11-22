import Foundation

/// The domains surface of the paired Maurice server — the member's domains
/// and reading companions, the brief of a domain (read, corrected, erased,
/// rewritten now), the conversations Maurice opened on his own, and the
/// device token that lets the server notify this phone. Same conventions as
/// `CalibreAPI` / `GardenAPI`: base URL from the App Group, the active
/// member's bearer token, a fail-fast timeout.
///
/// Routes: maurice/server/src/routes/domains.ts, conversations.ts, users.ts,
/// maurices.ts.
enum DomainsAPI {

    private static var base: String { "\(CarnetAPI.baseURL)/api" }

    // MARK: - Request helpers

    private static func authed(_ url: URL, method: String = "GET", json body: [String: Any]? = nil,
                               timeout: TimeInterval = 15, token: String? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        if let token = token ?? CarnetAPI.authToken {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    /// The body and the status: the brief routes say things with 404 (a
    /// companion has no brief), 429 (allowance spent) and 502 (the model
    /// failed) that the caller wants to tell apart.
    private static func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await CarnetAPI.fetch(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    private static func run(_ request: URLRequest) async throws -> Data {
        let (data, status) = try await send(request)
        guard (200...299).contains(status) else {
            throw CarnetAPI.APIError.serverError(errorMessage(data, status: status))
        }
        return data
    }

    private static func errorMessage(_ data: Data, status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = obj["error"] as? String {
            return msg
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.isEmpty ? "HTTP \(status)" : raw
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, context: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("[DomainsAPI] \(context) decode error: \(error)")
            if let raw = String(data: data, encoding: .utf8) {
                print("[DomainsAPI] raw (first 500): \(String(raw.prefix(500)))")
            }
            throw error
        }
    }

    // MARK: - Domains and companions

    /// GET /api/domains — the member's domains (each with when its brief was
    /// last written and by whom) and reading companions (each with its book
    /// and pinned conversation).
    static func overview() async throws -> DomainsOverview {
        let data = try await run(authed(URL(string: "\(base)/domains")!))
        return try decode(DomainsOverview.self, from: data, context: "domains")
    }

    // MARK: - The brief

    /// GET /api/domains/:id/brief — nil brief when the night has not written
    /// one yet; throws on 404 (not the member's domain, or a companion).
    static func brief(domainId: String) async throws -> BriefResponse {
        let data = try await run(authed(URL(string: "\(base)/domains/\(domainId)/brief")!))
        return try decode(BriefResponse.self, from: data, context: "brief")
    }

    private struct BriefEnvelope: Codable { let brief: DomainBrief? }

    /// PUT /api/domains/:id/brief — the member's correction: what Maurice
    /// reads from the next turn on, and what the next night starts from. An
    /// empty text erases the brief (nil comes back).
    static func setBrief(domainId: String, text: String) async throws -> DomainBrief? {
        let url = URL(string: "\(base)/domains/\(domainId)/brief")!
        let data = try await run(authed(url, method: "PUT", json: ["text": text]))
        return try decode(BriefEnvelope.self, from: data, context: "setBrief").brief
    }

    /// DELETE /api/domains/:id/brief — Maurice forgets what he kept.
    static func eraseBrief(domainId: String) async throws {
        _ = try await run(authed(URL(string: "\(base)/domains/\(domainId)/brief")!, method: "DELETE"))
    }

    /// POST /api/domains/:id/brief/refresh — rewrite the brief now, from
    /// whatever touched the domain since the last one. One model call on the
    /// night's model, seconds; the outcome says what happened.
    static func refreshBrief(domainId: String) async throws -> (outcome: BriefRefreshOutcome, brief: DomainBrief?) {
        let url = URL(string: "\(base)/domains/\(domainId)/brief/refresh")!
        let (data, status) = try await send(authed(url, method: "POST", timeout: 120))
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        var brief: DomainBrief?
        if let b = obj["brief"] as? [String: Any], let bd = try? JSONSerialization.data(withJSONObject: b) {
            brief = try? JSONDecoder().decode(DomainBrief.self, from: bd)
        }
        let error = obj["error"] as? String ?? ""
        switch (status, obj["outcome"] as? String) {
        case (200, "written"): return (.written(sources: obj["sources"] as? Int ?? 0), brief)
        case (200, "unchanged"): return (.unchanged, brief)
        case (429, _): return (.capped, brief)
        case (502, _): return (.failed(error.isEmpty ? "The model failed." : error), brief)
        default: return (.failed(error.isEmpty ? "HTTP \(status)" : error), brief)
        }
    }

    // MARK: - Reading companions

    /// POST /api/maurices — follow a book with Maurice: a row of kind
    /// `companion` bound to the book at the reading position (the composer's
    /// `progress` scope), which is what the Maurice app's pinned conversation
    /// then opens on. `kind` is sent explicitly: a client that omits it gets a
    /// domain, and a book is not a domain.
    static func createCompanion(name: String, bookId: Int) async throws {
        let url = URL(string: "\(base)/maurices")!
        _ = try await run(authed(url, method: "POST", json: [
            "name": name,
            "kind": "companion",
            "tagline": "",
            "context": [[
                "type": "book",
                "id": bookId,
                "representation": "summary",
                "scope": ["mode": "progress"],
            ]],
        ]))
    }

    // MARK: - Conversations Maurice opened

    /// GET /api/conversations — the member's recent conversations; Carnet
    /// keeps the ones Maurice opened (see `ConversationRow.openedByMaurice`).
    static func conversations(limit: Int = 100) async throws -> [ConversationRow] {
        let data = try await run(authed(URL(string: "\(base)/conversations?limit=\(limit)")!))
        return try decode([ConversationRow].self, from: data, context: "conversations")
    }

    /// GET /api/conversations/:id — the thread.
    static func conversation(id: String) async throws -> ConversationDetail {
        let data = try await run(authed(URL(string: "\(base)/conversations/\(id)")!))
        return try decode(ConversationDetail.self, from: data, context: "conversation")
    }

    /// POST /api/conversations/:id/read — opening it marks it read (the
    /// unread dot and the household badge follow).
    static func markRead(conversationId: String) async throws {
        _ = try await run(authed(URL(string: "\(base)/conversations/\(conversationId)/read")!, method: "POST"))
    }

    // MARK: - Push

    /// The platform the token is registered under. Distinct from the Maurice
    /// app's `ios`: an APNs token is for one app, and the server picks the
    /// topic (the bundle id) from this value.
    static let pushPlatform = "carnet-ios"

    /// POST /api/users/me/device-token — register this device with one
    /// household's server, tagged with the local household id so a push can
    /// say which household it came from.
    ///
    /// With the keys the notification extension opens sealed pushes with
    /// (PushSeal). A household older than sealed pushes refuses keys beside an
    /// Apple token: the token is then registered alone, and pushed in clear.
    static func registerDeviceToken(_ token: String, householdTag: String, baseURL: String, bearer: String) async throws {
        let url = URL(string: "\(baseURL)/api/users/me/device-token")!
        let body: [String: Any] = ["token": token, "platform": pushPlatform, "household_tag": householdTag]
        if let keys = PushSeal.keys() {
            var sealed = body
            sealed["keys"] = ["p256dh": keys.p256dh, "auth": keys.auth]
            if (try? await run(authed(url, method: "POST", json: sealed, token: bearer))) != nil { return }
        }
        _ = try await run(authed(url, method: "POST", json: body, token: bearer))
    }
}
