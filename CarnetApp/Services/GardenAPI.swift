import Foundation

/// Garden API client — the saved-articles and garden-entries surface of the
/// paired Maurice server. Mirrors `CalibreAPI`'s conventions (base URL from
/// the App Group, the active member's bearer token, fail-fast timeout).
/// Endpoint shapes are from maurice/server/data-api/routes/garden-articles.ts
/// and garden-entries.ts.
enum GardenAPI {

    private static var base: String { "\(CarnetAPI.baseURL)/api/v1/garden" }

    // MARK: - Request helpers (same shape as CalibreAPI's)

    private static func authed(_ url: URL, method: String = "GET", json body: [String: Any]? = nil,
                               timeout: TimeInterval = 15) -> URLRequest {
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

    private static func run(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await CarnetAPI.fetch(request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CarnetAPI.APIError.serverError(String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, context: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("[GardenAPI] \(context) decode error: \(error)")
            if let raw = String(data: data, encoding: .utf8) {
                print("[GardenAPI] raw (first 500): \(String(raw.prefix(500)))")
            }
            throw error
        }
    }

    private static func articleURL(_ slug: String, locale: String, suffix: String = "", owner: String? = nil) -> URL {
        let s = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        var components = URLComponents(string: "\(base)/articles/\(s)\(suffix)")!
        components.queryItems = [URLQueryItem(name: "locale", value: locale)]
        if let owner { components.queryItems?.append(URLQueryItem(name: "owner", value: owner)) }
        return components.url!
    }

    // MARK: - Articles

    private struct ArticlesList: Codable { let articles: [Article] }

    /// GET /garden/articles — every saved article, newest first.
    static func articles() async throws -> [Article] {
        let data = try await run(authed(URL(string: "\(base)/articles")!))
        return try decode(ArticlesList.self, from: data, context: "articles").articles
    }

    /// GET /garden/articles/:slug — metadata + the fiche's markdown body.
    static func article(slug: String, locale: String) async throws -> ArticleDetail {
        let data = try await run(authed(articleURL(slug, locale: locale)))
        return try decode(ArticleDetail.self, from: data, context: "article")
    }

    /// GET /garden/articles/:slug/text — the captured full text.
    /// 404 means the page was never captured (a bookmark). `owner`: an
    /// article given from another household, read in its owner's notes.
    static func articleText(slug: String, locale: String, owner: String? = nil) async throws -> ArticleText {
        let data = try await run(authed(articleURL(slug, locale: locale, suffix: "/text", owner: owner), timeout: 30))
        return try decode(ArticleText.self, from: data, context: "articleText")
    }

    /// POST /garden/articles/:slug/comment — a dated note under the fiche's
    /// « Commentaire ». Writing on the fiche is what opens it, so this is also
    /// how an unopened one (a bare share) becomes a fiche.
    static func addComment(slug: String, locale: String, comment: String) async throws -> ArticleDetail {
        let url = URL(string: "\(base)/articles/\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)/comment")!
        let data = try await run(authed(url, method: "POST", json: ["locale": locale, "comment": comment]))
        return try decode(ArticleDetail.self, from: data, context: "addComment")
    }

    private struct SummaryResponse: Codable {
        let summary: String
        let summary_long: String?
    }

    /// The same, both summaries: the paragraph and the long one.
    static func summaries(slug: String, locale: String, force: Bool = false) async throws -> ShelfSource.Summary {
        let url = URL(string: "\(base)/articles/\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)/summary")!
        let data = try await run(authed(url, method: "POST",
                                        json: ["locale": locale, "force": force], timeout: 180))
        let r = try decode(SummaryResponse.self, from: data, context: "summarize")
        return ShelfSource.Summary(text: r.summary, long: r.summary_long, current: true)
    }

    /// POST /garden/articles/:slug/summary — generate (or regenerate) the
    /// summary and wait for it. Slow: the server runs an LLM pass.
    static func summarize(slug: String, locale: String, force: Bool = false) async throws -> String {
        let url = URL(string: "\(base)/articles/\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)/summary")!
        let data = try await run(authed(url, method: "POST",
                                        json: ["locale": locale, "force": force], timeout: 180))
        return try decode(SummaryResponse.self, from: data, context: "summarize").summary
    }

    // MARK: - Article highlights
    //
    // Same rows as book highlights, anchored by locale+slug instead of
    // book_id+chapter_slug. Decoded into the shared `Highlight` model (what
    // HighlightableText renders) with the article's slug standing in for the
    // chapter slug.

    private struct ArticleHighlightDTO: Codable {
        let id: Int
        let slug: String
        let quote: String
        let note: String?
        let color: String
        let start_offset: Int?
        let end_offset: Int?
        let view: String?
        let created_at: String?
        /// The conversation with Maurice opened from the passage; the list
        /// sends what it came to as well.
        var conversation_id: String? = nil
        var conversation: HighlightConversation? = nil

        var asHighlight: Highlight {
            Highlight(id: id, bookId: nil, chapterSlug: slug, quote: quote, note: note,
                      color: color, startOffset: start_offset, endOffset: end_offset,
                      view: view, createdAt: created_at,
                      conversationId: conversation_id, conversation: conversation)
        }
    }

    /// GET /garden/articles/:slug/highlights
    static func highlights(slug: String, locale: String) async throws -> [Highlight] {
        let data = try await run(authed(articleURL(slug, locale: locale, suffix: "/highlights")))
        return try decode([ArticleHighlightDTO].self, from: data, context: "highlights").map(\.asHighlight)
    }

    /// POST /garden/articles/:slug/highlights
    @discardableResult
    static func createHighlight(slug: String, locale: String, quote: String, color: String,
                                note: String? = nil, startOffset: Int? = nil, endOffset: Int? = nil,
                                view: String = "full") async throws -> Highlight {
        var body: [String: Any] = ["quote": quote, "color": color, "view": view, "locale": locale]
        if let note { body["note"] = note }
        if let startOffset { body["start_offset"] = startOffset }
        if let endOffset { body["end_offset"] = endOffset }
        let url = URL(string: "\(base)/articles/\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)/highlights")!
        let data = try await run(authed(url, method: "POST", json: body))
        return try decode(ArticleHighlightDTO.self, from: data, context: "createHighlight").asHighlight
    }

    /// PUT /garden/articles/:slug/highlights/:id
    @discardableResult
    static func updateHighlight(slug: String, highlightId: Int, note: String? = nil,
                                color: String? = nil) async throws -> Highlight {
        var body: [String: Any] = [:]
        if let note { body["note"] = note } else { body["note"] = NSNull() }
        if let color { body["color"] = color }
        let url = URL(string: "\(base)/articles/\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)/highlights/\(highlightId)")!
        let data = try await run(authed(url, method: "PUT", json: body))
        return try decode(ArticleHighlightDTO.self, from: data, context: "updateHighlight").asHighlight
    }

    /// DELETE /garden/articles/:slug/highlights/:id
    static func deleteHighlight(slug: String, highlightId: Int) async throws {
        let url = URL(string: "\(base)/articles/\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)/highlights/\(highlightId)")!
        _ = try await run(authed(url, method: "DELETE"))
    }

    // MARK: - Résonances (wiki-links)

    private struct TargetsList: Codable { let targets: [LinkTarget] }

    /// GET /garden/links/targets?q=… — autocomplete over the garden's entries.
    static func linkTargets(query: String) async throws -> [LinkTarget] {
        var comps = URLComponents(string: "\(base)/links/targets")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        let data = try await run(authed(comps.url!))
        return try decode(TargetsList.self, from: data, context: "linkTargets").targets
    }

    /// POST /garden/links — append a dated [[wiki-link]] block to the target's
    /// fiche. `sourceBasename` when the source lives in the garden (an article
    /// fiche); `sourceBookTitle` lets the server match a Calibre book to its
    /// garden fiche, falling back to a plain-text label.
    @discardableResult
    static func createResonance(to target: LinkTarget, comment: String, quote: String? = nil,
                                sourceLabel: String? = nil, sourceBasename: String? = nil,
                                sourceBookTitle: String? = nil) async throws -> Data {
        var body: [String: Any] = [
            "to": ["locale": target.locale, "slug": target.slug, "collection": target.collection],
        ]
        // The server wants at least one of the two; send only what's non-empty.
        if !comment.isEmpty { body["comment"] = comment }
        if let quote, !quote.isEmpty { body["quote"] = quote }
        if let sourceLabel {
            var source: [String: Any] = ["label": sourceLabel]
            if let sourceBasename { source["basename"] = sourceBasename }
            body["source"] = source
        } else if let sourceBookTitle {
            body["source_book_title"] = sourceBookTitle
        }
        return try await run(authed(URL(string: "\(base)/links")!, method: "POST", json: body))
    }

    // MARK: - The shelf

    /// GET /garden/entries?view=shelf — one list of entries of every kind,
    /// each with its source, the member's side and the shared side.
    /// `archived` asks for the other half: what the member put away.
    static func shelf(archived: Bool = false) async throws -> ShelfResponse {
        let data = try await run(authed(URL(string: "\(base)/entries?view=shelf\(archived ? "&archived=1" : "")")!, timeout: 30))
        return try decode(ShelfResponse.self, from: data, context: "shelf")
    }

    /// GET /garden/entries?view=notes — every note the member wrote, whatever
    /// the entry, newest first.
    static func notes() async throws -> NotesResponse {
        let data = try await run(authed(URL(string: "\(base)/entries?view=notes")!, timeout: 30))
        return try decode(NotesResponse.self, from: data, context: "notes")
    }

    /// GET /garden/entries/:collection/:locale/:slug — both faces in full.
    static func entryDetail(_ entry: ShelfEntry) async throws -> EntryDetail? {
        guard let url = entryURL(entry, "") else { return nil }
        return try decode(EntryDetail.self, from: try await run(authed(url)), context: "entry")
    }

    /// The same page with its row: what the list said of the entry may be
    /// old — who it is shared with, how many notes it holds.
    static func entryPage(_ entry: ShelfEntry) async throws -> Written? {
        guard let url = entryURL(entry, "") else { return nil }
        return try written(try await run(authed(url)), context: "entry")
    }

    /// An entry of the member's own by what names it, for a screen that was
    /// opened on its source — the reader — and has no row in hand.
    static func entryPage(collection: String, locale: String, slug: String) async throws -> Written {
        let s = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        let data = try await run(authed(URL(string: "\(base)/entries/\(collection)/\(locale)/\(s)")!))
        return try written(data, context: "entry")
    }

    // MARK: - Conversations about an entry

    private struct ConversationsResponse: Decodable { let conversations: [EntryConversation] }
    private struct ConversationSummaryResponse: Decodable { let summary: EntryConversation.Summary }

    /// GET …/conversations — the member's conversations with Maurice about
    /// this entry, newest first, each with the summary its fiche keeps.
    static func conversations(about entry: ShelfEntry) async throws -> [EntryConversation] {
        guard !entry.isForeign, let url = entryURL(entry, "/conversations") else { return [] }
        return try decode(ConversationsResponse.self, from: try await run(authed(url)), context: "conversations").conversations
    }

    /// POST …/conversations/:id/summary — what the conversation came to, as the
    /// fiche keeps it: read back when up to date, written (a model pass, slow)
    /// when missing or when the conversation went on since.
    static func conversationSummary(_ entry: ShelfEntry, conversation id: String, force: Bool = false) async throws -> EntryConversation.Summary {
        guard let url = entryURL(entry, "/conversations/\(id)/summary") else {
            throw CarnetAPI.APIError.serverError("No entry.")
        }
        let data = try await run(authed(url, method: "POST", json: ["force": force], timeout: 180))
        return try decode(ConversationSummaryResponse.self, from: data, context: "conversationSummary").summary
    }

    // MARK: - Sharing an entry

    /// POST …/participants — share the entry with a member of the household.
    static func share(_ entry: ShelfEntry, with memberId: String) async throws -> Written {
        guard let url = entryURL(entry, "/participants") else { throw CarnetAPI.APIError.serverError("No entry to share.") }
        return try written(try await run(authed(url, method: "POST", json: ["member_id": memberId])), context: "share")
    }

    /// DELETE …/participants/:id — the owner takes a member off, or a member
    /// takes themselves off (nothing comes back then: the entry is no longer theirs to read).
    @discardableResult
    static func unshare(_ entry: ShelfEntry, memberId: String) async throws -> Written? {
        guard let url = entryURL(entry, "/participants/\(memberId)") else { throw CarnetAPI.APIError.serverError("No entry.") }
        let data = try await run(authed(url, method: "DELETE"))
        return try? written(data, context: "unshare")
    }

    // MARK: - Writing on an entry

    /// What a write answers with: the entry as it now reads, row and faces.
    struct Written {
        let entry: ShelfEntry
        let detail: EntryDetail
        let deploy: DeployState?
    }

    private struct DeployEnvelope: Codable { let deploy: DeployState? }

    private static func written(_ data: Data, context: String) throws -> Written {
        Written(entry: try decode(ShelfEntry.self, from: data, context: context),
                detail: try decode(EntryDetail.self, from: data, context: context),
                deploy: (try? JSONDecoder().decode(DeployEnvelope.self, from: data))?.deploy)
    }

    private static func entryURL(_ entry: ShelfEntry, _ suffix: String) -> URL? {
        guard let collection = entry.collection, let locale = entry.locale, let slug = entry.slug else { return nil }
        let s = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        // Another member's entry is read where it lives: in their garden.
        let owner = entry.owner.map {
            "?owner=\($0.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.username)"
        } ?? ""
        return URL(string: "\(base)/entries/\(collection)/\(locale)/\(s)\(suffix)\(owner)")
    }

    private static func noteBody(text: String, quote: String?, page: String?, chapterTitle: String?) -> [String: Any] {
        var body: [String: Any] = ["text": text]
        if let quote, !quote.isEmpty { body["quote"] = quote }
        var place: [String: Any] = [:]
        if let page, !page.isEmpty { place["page"] = page }
        if let chapterTitle, !chapterTitle.isEmpty { place["chapter_title"] = chapterTitle }
        if !place.isEmpty { body["where"] = place }
        return body
    }

    /// A note on the member's side of an entry. A book of the library with no
    /// entry yet gets one on the way (`from-book`).
    static func addNote(to entry: ShelfEntry, text: String, quote: String? = nil, page: String? = nil) async throws -> Written {
        var body = noteBody(text: text, quote: quote, page: page, chapterTitle: nil)
        let url: URL
        if let u = entryURL(entry, "/notes") {
            url = u
        } else if let bookId = entry.source?.bookId {
            body["book_id"] = bookId
            url = URL(string: "\(base)/entries/from-book")!
        } else {
            throw CarnetAPI.APIError.serverError("This entry cannot be written on.")
        }
        return try written(try await run(authed(url, method: "POST", json: body, timeout: 30)), context: "note")
    }

    // MARK: - Editing a note
    //
    // PATCH / DELETE …/notes/:id[?owner=]. The two calls and what their
    // answers mean are kept here, in one place, so their shapes can follow
    // the server's. No offline queue: an edit needs the network.

    /// Why a note could not be rewritten or taken off.
    enum NoteEditError: Error {
        /// 404 (`note_not_found` or `changed`): the note is not what the
        /// member saw any more — written over, or gone.
        case changed
        /// 403: not theirs to edit.
        case forbidden
    }

    private static func noteURL(_ entry: ShelfEntry, _ noteId: String) -> URL? {
        let id = noteId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? noteId
        return entryURL(entry, "/notes/\(id)")
    }

    private static func runNoteEdit(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await CarnetAPI.fetch(request)
        guard let http = response as? HTTPURLResponse else { throw CarnetAPI.APIError.serverError("") }
        switch http.statusCode {
        case 200...299: return data
        case 404: throw NoteEditError.changed
        case 403: throw NoteEditError.forbidden
        default: throw CarnetAPI.APIError.serverError(String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// PATCH …/notes/:id — `{text, quote?, page?}`; answers `{note: {…}}`,
    /// which the caller does not need: it reads the entry again.
    static func editNote(_ entry: ShelfEntry, noteId: String, text: String, quote: String?, page: String?) async throws {
        guard let url = noteURL(entry, noteId) else { throw NoteEditError.changed }
        var body: [String: Any] = ["text": text]
        if let quote, !quote.isEmpty { body["quote"] = quote }
        if let page, !page.isEmpty { body["page"] = page }
        _ = try await runNoteEdit(authed(url, method: "PATCH", json: body, timeout: 30))
    }

    /// DELETE …/notes/:id — 204.
    static func deleteNote(_ entry: ShelfEntry, noteId: String) async throws {
        guard let url = noteURL(entry, noteId) else { throw NoteEditError.changed }
        _ = try await runNoteEdit(authed(url, method: "DELETE", timeout: 30))
    }

    /// A note taken while reading a book: it lands on the book's entry, made
    /// on the spot when the book had none, with the chapter it was taken in.
    static func addBookNote(bookId: Int, text: String, chapterTitle: String?) async throws {
        var body = noteBody(text: text, quote: nil, page: nil, chapterTitle: chapterTitle)
        body["book_id"] = bookId
        _ = try await run(authed(URL(string: "\(base)/entries/from-book")!, method: "POST", json: body, timeout: 30))
    }

    /// The shared side: the body of the card, a draft until published.
    static func writeShared(_ entry: ShelfEntry, body: String, title: String?) async throws -> Written {
        guard let url = entryURL(entry, "/shared") else { throw CarnetAPI.APIError.serverError("No entry to write on.") }
        var json: [String: Any] = ["body": body]
        if let title, !title.isEmpty { json["title"] = title }
        return try written(try await run(authed(url, method: "PUT", json: json, timeout: 30)), context: "shared")
    }

    /// POST …/details — complete the card from what the fiche knows of its
    /// subject: the fields of its kind it lacks, and its cover.
    static func refreshDetails(_ entry: ShelfEntry) async throws -> Written {
        guard let url = entryURL(entry, "/details") else { throw CarnetAPI.APIError.serverError("No entry to complete.") }
        return try written(try await run(authed(url, method: "POST", timeout: 45)), context: "details")
    }

    /// PUT …/book — the library's book this entry is about, named by the
    /// member; answers the entry with that book as its source.
    static func linkBook(_ entry: ShelfEntry, bookId: Int) async throws -> Written {
        guard let url = entryURL(entry, "/book") else { throw CarnetAPI.APIError.serverError("No entry to tie to a book.") }
        return try written(try await run(authed(url, method: "PUT", json: ["book_id": bookId])), context: "book")
    }

    /// The entry's cover, read on this device (`LinkCover`) and handed over.
    static func setCover(_ entry: ShelfEntry, jpeg: Data) async throws -> Written {
        guard let collection = entry.collection, let locale = entry.locale, let slug = entry.slug else {
            throw CarnetAPI.APIError.serverError("No entry to give a cover to.")
        }
        return try written(try await CarnetAPI.setCover(collection: collection, locale: locale, slug: slug, jpeg: jpeg), context: "cover")
    }

    /// Publish or unpublish: the card's flag, then a deploy of the site.
    static func setPublished(_ entry: ShelfEntry, _ on: Bool) async throws -> Written {
        guard let url = entryURL(entry, "/shared/publish") else { throw CarnetAPI.APIError.serverError("No entry to publish.") }
        return try written(try await run(authed(url, method: on ? "POST" : "DELETE", timeout: 30)), context: "publish")
    }

    /// DELETE /garden/entries/:collection/:locale/:slug — both faces leave the
    /// garden, in every locale of the subject. A book of the library with no
    /// entry has nothing to delete.
    static func deleteEntry(_ entry: ShelfEntry) async throws {
        guard let url = entryURL(entry, "") else { throw CarnetAPI.APIError.serverError("Nothing to delete.") }
        _ = try await run(authed(url, method: "DELETE", timeout: 30))
    }

    /// POST /garden/entries/archive — put a row away from the list, or bring
    /// it back. Nothing in the garden changes.
    static func setArchived(_ entry: ShelfEntry, _ on: Bool) async throws {
        _ = try await run(authed(URL(string: "\(base)/entries/archive")!, method: "POST",
                                 json: ["id": entry.id, "archived": on]))
    }

    /// GET /garden/site/deploy — where the site deploy stands.
    static func deployState() async throws -> DeployState {
        let data = try await run(authed(URL(string: "\(base)/site/deploy")!))
        return try decode(DeployState.self, from: data, context: "deploy")
    }

    // MARK: - Garden entries

    /// GET /garden/entries — every entry across every collection.
    static func entries() async throws -> GardenEntriesResponse {
        let data = try await run(authed(URL(string: "\(base)/entries")!, timeout: 30))
        return try decode(GardenEntriesResponse.self, from: data, context: "entries")
    }
}
