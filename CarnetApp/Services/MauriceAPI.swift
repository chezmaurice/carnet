import Foundation

/// Talking to Maurice from an entry, and what the exchange is worth keeping.
///
/// A conversation opened here is held *from* the entry: the server loads the
/// entry's fiche as its context and, after each reply, names what the
/// exchange established — a note for this entry first, then the other works
/// and people it touched (maurice/server/src/services/entrySuggestions.ts).
/// Nothing reaches the garden until the member keeps a row; a note kept
/// carries a link back to the conversation it came from.
///
/// Routes: maurice/server/src/routes/conversations.ts, suggestions.ts. Same
/// conventions as `DomainsAPI`: base URL from the App Group, the active
/// member's bearer token.
enum MauriceAPI {

    private static var base: String { "\(CarnetAPI.baseURL)/api" }

    private static func authed(_ url: URL, method: String = "GET", json body: [String: Any]? = nil,
                               timeout: TimeInterval = 20) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        if let token = CarnetAPI.authToken {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private static func message(_ data: Data, status: Int) -> String {
        if let refusal = AIConsentStore.refusalMessage(data, status: status) { return refusal }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = obj["error"] as? String {
            return msg
        }
        return "HTTP \(status)"
    }

    private static func run(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await CarnetAPI.fetch(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw CarnetAPI.APIError.serverError(message(data, status: status))
        }
        return data
    }

    // MARK: - Conversations

    private struct Created: Decodable { let id: String }

    /// POST /api/conversations `{entry}` — a new conversation held from an
    /// entry (`<collection>/<locale>/<slug>`), its fiche loaded as context.
    static func open(from entry: String) async throws -> String {
        let data = try await run(authed(URL(string: "\(base)/conversations")!, method: "POST", json: ["entry": entry]))
        return try JSONDecoder().decode(Created.self, from: data).id
    }

    /// POST /api/conversations `{entry, article_highlight}` — a conversation
    /// held from an article, on a passage just highlighted in its reader,
    /// which then leads to it.
    static func open(from entry: String, articleHighlight: Int) async throws -> String {
        let data = try await run(authed(URL(string: "\(base)/conversations")!, method: "POST",
                                        json: ["entry": entry, "article_highlight": articleHighlight]))
        return try JSONDecoder().decode(Created.self, from: data).id
    }

    /// POST /api/conversations `{book, chapter | highlight}` — a new
    /// conversation held from the reader: the book's entry (made if it had
    /// none), its fiche and the book up to where the member is, and where it
    /// starts — the chapter open there, or a passage just highlighted, which
    /// then leads to it.
    static func open(book: Int, chapter: String? = nil, highlight: Int? = nil) async throws -> String {
        var body: [String: Any] = ["book": book]
        if let highlight { body["highlight"] = highlight } else if let chapter { body["chapter"] = chapter }
        let data = try await run(authed(URL(string: "\(base)/conversations")!, method: "POST", json: body))
        return try JSONDecoder().decode(Created.self, from: data).id
    }

    /// One line of the reply's stream that Carnet acts on.
    enum Event {
        case text(String)
        /// Maurice is doing something before he speaks: thinking, a tool.
        case working
        case failed(String)
    }

    /// POST /api/conversations/:id/messages — the reply, as it is written.
    /// The server answers newline-delimited JSON; the turn goes on there even
    /// if this request is dropped, and the thread read again shows the reply.
    static func send(_ text: String, to conversationId: String) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = authed(URL(string: "\(base)/conversations/\(conversationId)/messages")!,
                                         method: "POST", json: ["content": text], timeout: 300)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse { CarnetAPI.note(http, for: request) }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200...299).contains(status) else {
                        var body = Data()
                        for try await b in bytes { body.append(b) }
                        throw CarnetAPI.APIError.serverError(message(body, status: status))
                    }
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = obj["type"] as? String else { continue }
                        switch type {
                        case "text_delta":
                            if let t = obj["text"] as? String { continuation.yield(.text(t)) }
                        case "thinking", "tool_call":
                            continuation.yield(.working)
                        case "error":
                            continuation.yield(.failed((obj["error"] as? String) ?? (obj["message"] as? String) ?? "Maurice could not answer."))
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - What is worth keeping

    /// GET /api/suggestions?conversation=… — the conversation's list. With
    /// `settle`, the server answers once the pass the last reply started is
    /// done: Carnet keeps no socket to hear about it.
    static func suggestions(for conversationId: String, settle: Bool = false) async throws -> SuggestionList {
        let url = URL(string: "\(base)/suggestions?conversation=\(conversationId)\(settle ? "&settle=1" : "")")!
        let data = try await run(authed(url, timeout: settle ? 30 : 15))
        return try JSONDecoder().decode(SuggestionList.self, from: data)
    }

    /// POST /api/suggestions/:id/keep — the entry is made if the garden has
    /// none, the note filed on it, and — kept from a conversation held on
    /// another entry — the two are linked.
    /// Returns the row as kept: its `entry` is the fiche to open.
    @discardableResult
    static func keep(_ id: String, candidate: String? = nil, episodes: [String] = []) async throws -> Suggestion? {
        var body: [String: Any] = [:]
        if let candidate { body["candidate"] = candidate }
        if !episodes.isEmpty { body["episodes"] = episodes }
        let data = try await run(authed(URL(string: "\(base)/suggestions/\(id)/keep")!, method: "POST", json: body, timeout: 40))
        return try? JSONDecoder().decode(Suggestion.self, from: data)
    }

    /// POST /api/suggestions/from-text — what the member describes in their
    /// own words (« the last Houellebecq », « Hannah Arendt »), named and
    /// looked up as a conversation's subjects are, with no conversation. The
    /// rows are the same: kept, searched, dismissed by the routes here.
    static func suggestions(fromText text: String, locale: String? = nil) async throws -> SuggestionList {
        var body: [String: Any] = ["text": text]
        if let locale { body["locale"] = locale }
        let data = try await run(authed(URL(string: "\(base)/suggestions/from-text")!, method: "POST", json: body, timeout: 60))
        return try JSONDecoder().decode(SuggestionList.self, from: data)
    }

    /// GET /api/suggestions?batch=… — a from-text list, read again.
    static func suggestions(batch: String) async throws -> SuggestionList {
        let url = URL(string: "\(base)/suggestions?batch=\(batch)")!
        let data = try await run(authed(url, timeout: 15))
        return try JSONDecoder().decode(SuggestionList.self, from: data)
    }

    /// GET /api/suggestions/:id/episodes — a podcast's recent episodes, and the
    /// one Maurice reads the conversation as being about. `feed` is the show
    /// picked when the suggestion had several.
    static func episodes(_ id: String, feed: String? = nil) async throws -> EpisodeList {
        let url = URL(string: "\(base)/suggestions/\(id)/episodes\(feed.map { "?feed=\($0)" } ?? "")")!
        let data = try await run(authed(url, timeout: 40))
        return try JSONDecoder().decode(EpisodeList.self, from: data)
    }

    /// POST /api/suggestions/:id/search — not the right one: look again.
    /// `query` is the member's own term; without it Maurice rephrases the
    /// search. Returns how many it found; none leaves the row as it was.
    static func search(_ id: String, query: String? = nil) async throws -> Int {
        var body: [String: Any] = [:]
        if let query { body["query"] = query }
        let data = try await run(authed(URL(string: "\(base)/suggestions/\(id)/search")!, method: "POST", json: body, timeout: 40))
        return (try? JSONDecoder().decode(SearchAnswer.self, from: data))?.found ?? 0
    }

    private struct SearchAnswer: Decodable { let found: Int }

    /// POST /api/suggestions/:id/dismiss.
    static func dismiss(_ id: String) async throws {
        _ = try await run(authed(URL(string: "\(base)/suggestions/\(id)/dismiss")!, method: "POST", json: [:]))
    }
}

// MARK: - Models

/// A show's recent episodes, newest first.
struct EpisodeList: Decodable, Equatable {
    struct Episode: Decodable, Identifiable, Equatable {
        let id: String
        let title: String
        /// When it came out, ISO-8601.
        let date: String?
        let description: String
        let image: String
        /// Seconds.
        let duration: Int?
    }
    let feed: String
    let episodes: [Episode]
    /// The one the conversation was about, as Maurice reads it.
    let suggested: String?
}

struct SuggestionList: Decodable {
    /// The entry the conversation is held from, when it is.
    let entry: String?
    /// A from-text list's id, to read it again.
    let batch: String?
    let suggestions: [Suggestion]
    let pending: Int
    let kept: Int
}

/// Something a conversation offers to keep: a work or a person, and the note
/// that would be filed on it.
struct Suggestion: Decodable, Identifiable, Hashable {
    struct Candidate: Decodable, Identifiable, Hashable {
        let id: String
        let title: String
        let year: Int?
        let subtitle: String?
        /// Its poster, sleeve or portrait: absolute, or a path on the server.
        let image: String?
    }

    let id: String
    let kind: String
    let title: String
    let year: Int?
    let subtitle: String?
    /// Its poster, sleeve or portrait: absolute, or a path on the server.
    let image: String?
    let note: String
    let state: String
    /// Already an entry of the member's.
    let existing: Bool
    /// The entry the conversation is held from: the note is its result.
    let bound: Bool
    /// Keeping it links it to the entry the conversation is held from.
    let links: Bool
    /// Several possible identities: one is picked before keeping.
    let candidates: [Candidate]
    /// `<collection>/<locale>/<slug>`, once it is an entry.
    let entry: String?
    /// The last term searched for it, once the member asked for another look.
    let query: String?
    /// Whether another look makes sense: not for the conversation's own
    /// entry, nor for someone from the member's life, never looked up.
    let searchable: Bool?

    var isKept: Bool { state == "kept" }

    var kindLabel: String {
        switch kind {
        case "movies", "series", "books", "music", "podcasts", "games", "people", "articles", "posts":
            return L("suggest.kind.\(kind)")
        default: return "Entry"
        }
    }
}
