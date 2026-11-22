import Foundation

extension Error {
    /// True when this is a Swift task cancellation or a cancelled URL request —
    /// which under SwiftUI usually means the view churned, not a real failure.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

/// Reading API client — the Calibre surface of the paired Maurice server.
/// Mirrors `CarnetAPI`'s conventions (base URL from the App Group, the active
/// member's bearer token on every request, `CarnetAPI.APIError` for failures).
/// Endpoint shapes are from maurice-web/src/pages/books/**.
enum CalibreAPI {

    private static var base: String { "\(CarnetAPI.baseURL)/api/v1/calibre" }

    // MARK: - Request helpers

    private static func authed(_ url: URL, method: String = "GET", json body: [String: Any]? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 15   // fail fast when offline instead of hanging ~60s
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
            print("[CalibreAPI] \(context) decode error: \(error)")
            if let raw = String(data: data, encoding: .utf8) {
                print("[CalibreAPI] raw (first 500): \(String(raw.prefix(500)))")
            }
            throw error
        }
    }

    /// Some list endpoints return a bare array, others wrap it (`{ books: [...] }`).
    private static func decodeList<T: Decodable>(_ type: T.Type, key: String, from data: Data, context: String) throws -> [T] {
        if let arr = try? JSONDecoder().decode([T].self, from: data) { return arr }
        // Decode the wrapped form (`{ books: [...] }`) under a dynamic key.
        let obj = try decode([String: [T]].self, from: data, context: context)
        return obj[key] ?? obj.values.first ?? []
    }

    // MARK: - Library

    /// GET /books — the library list.
    static func books() async throws -> [Book] {
        let data = try await run(authed(URL(string: "\(base)/books")!))
        return try decodeList(Book.self, key: "books", from: data, context: "books")
    }

    /// GET /books/:id/metadata
    static func metadata(bookId: Int) async throws -> Book {
        let data = try await run(authed(URL(string: "\(base)/books/\(bookId)/metadata")!))
        return try decode(Book.self, from: data, context: "metadata")
    }

    // MARK: - Chapters

    /// GET /books/:id/chapters
    static func chapters(bookId: Int) async throws -> [Chapter] {
        let data = try await run(authed(URL(string: "\(base)/books/\(bookId)/chapters")!))
        return try decodeList(Chapter.self, key: "chapters", from: data, context: "chapters")
    }

    /// GET /books/:id/chapters/by-slug/:slug — full chapter text.
    static func chapter(bookId: Int, slug: String) async throws -> ChapterText {
        let s = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        let data = try await run(authed(URL(string: "\(base)/books/\(bookId)/chapters/by-slug/\(s)")!))
        return try decode(ChapterText.self, from: data, context: "chapter")
    }

    /// GET /books/:id/chapters/by-slug/:slug/summary
    static func chapterSummary(bookId: Int, slug: String) async throws -> ChapterSummary {
        let s = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        let data = try await run(authed(URL(string: "\(base)/books/\(bookId)/chapters/by-slug/\(s)/summary")!))
        return try decode(ChapterSummary.self, from: data, context: "chapterSummary")
    }

    // MARK: - Reading progress

    /// GET /books/:id/reading-progress — nil when the book hasn't been opened.
    static func readingProgress(bookId: Int) async throws -> ReadingProgress? {
        let data = try await run(authed(URL(string: "\(base)/books/\(bookId)/reading-progress")!))
        if data.isEmpty { return nil }
        return try? JSONDecoder().decode(ReadingProgress.self, from: data)
    }

    /// POST /books/:id/reading-progress — save the resume point. The server
    /// requires both the chapter index and slug, and keeps whatever is written
    /// last, from any device: it does not refuse a position behind the one it
    /// holds (ReadingPositionStore.reconcile). A paused book's write is a no-op.
    @discardableResult
    static func setReadingProgress(bookId: Int, chapterIndex: Int, chapterSlug: String, view: String, position: Double = 0) async throws -> ReadingProgress? {
        let url = URL(string: "\(base)/books/\(bookId)/reading-progress")!
        let data = try await run(authed(url, method: "POST",
            json: ["chapter_index": chapterIndex, "chapter_slug": chapterSlug, "view": view, "position": position]))
        return try? JSONDecoder().decode(ReadingProgress.self, from: data)
    }

    /// POST /books/:id/reading-progress/tracking — pause or resume recording.
    /// Paused, the marker is held where it is: consult an index or a chapter
    /// well ahead without it counting as read.
    @discardableResult
    static func setReadingTracking(bookId: Int, paused: Bool) async throws -> ReadingProgress? {
        let url = URL(string: "\(base)/books/\(bookId)/reading-progress/tracking")!
        let data = try await run(authed(url, method: "POST", json: ["paused": paused]))
        return try? JSONDecoder().decode(ReadingProgress.self, from: data)
    }

    /// DELETE /books/:id/reading-progress — forget the position entirely.
    static func resetReadingProgress(bookId: Int) async throws {
        let url = URL(string: "\(base)/books/\(bookId)/reading-progress")!
        _ = try await run(authed(url, method: "DELETE"))
    }

    // MARK: - Bookmarks & notes

    /// GET /books/:id/bookmarks
    static func bookmarks(bookId: Int) async throws -> [Bookmark] {
        let data = try await run(authed(URL(string: "\(base)/books/\(bookId)/bookmarks")!))
        return try decodeList(Bookmark.self, key: "bookmarks", from: data, context: "bookmarks")
    }

    /// POST /books/:id/bookmarks — toggle a chapter bookmark.
    @discardableResult
    static func toggleBookmark(bookId: Int, chapterSlug: String, view: String) async throws -> BookmarkToggleResponse {
        let url = URL(string: "\(base)/books/\(bookId)/bookmarks")!
        let data = try await run(authed(url, method: "POST", json: ["chapter_slug": chapterSlug, "view": view]))
        return try decode(BookmarkToggleResponse.self, from: data, context: "toggleBookmark")
    }

    /// PUT /books/:id/bookmarks/:bookmarkId — set/clear the note.
    static func updateBookmarkNote(bookId: Int, bookmarkId: Int, note: String?) async throws {
        let url = URL(string: "\(base)/books/\(bookId)/bookmarks/\(bookmarkId)")!
        _ = try await run(authed(url, method: "PUT", json: ["note": note as Any]))
    }

    /// DELETE /books/:id/bookmarks/:bookmarkId
    static func deleteBookmark(bookId: Int, bookmarkId: Int) async throws {
        let url = URL(string: "\(base)/books/\(bookId)/bookmarks/\(bookmarkId)")!
        _ = try await run(authed(url, method: "DELETE"))
    }

    // MARK: - Highlights (passage-level)

    /// GET /books/:id/highlights
    static func highlights(bookId: Int) async throws -> [Highlight] {
        let data = try await run(authed(URL(string: "\(base)/books/\(bookId)/highlights")!))
        return try decodeList(Highlight.self, key: "highlights", from: data, context: "highlights")
    }

    /// POST /books/:id/highlights — create a highlight from a selected range.
    @discardableResult
    static func createHighlight(bookId: Int, chapterSlug: String, quote: String,
                                color: String, note: String? = nil,
                                startOffset: Int? = nil, endOffset: Int? = nil,
                                view: String = "full") async throws -> Highlight {
        // `view` is what makes the offsets mean anything: a chapter has a full
        // text and a summary, and the same numbers land in different places.
        var body: [String: Any] = [
            "chapter_slug": chapterSlug, "quote": quote, "color": color, "view": view,
        ]
        if let note { body["note"] = note }
        if let startOffset { body["start_offset"] = startOffset }
        if let endOffset { body["end_offset"] = endOffset }
        let data = try await run(authed(URL(string: "\(base)/books/\(bookId)/highlights")!, method: "POST", json: body))
        return try decode(Highlight.self, from: data, context: "createHighlight")
    }

    /// PUT /books/:id/highlights/:hid — update note and/or colour.
    @discardableResult
    static func updateHighlight(bookId: Int, highlightId: Int, note: String? = nil, color: String? = nil) async throws -> Highlight {
        var body: [String: Any] = [:]
        if let note { body["note"] = note } else { body["note"] = NSNull() }
        if let color { body["color"] = color }
        let data = try await run(authed(URL(string: "\(base)/books/\(bookId)/highlights/\(highlightId)")!, method: "PUT", json: body))
        return try decode(Highlight.self, from: data, context: "updateHighlight")
    }

    /// DELETE /books/:id/highlights/:hid
    static func deleteHighlight(bookId: Int, highlightId: Int) async throws {
        _ = try await run(authed(URL(string: "\(base)/books/\(bookId)/highlights/\(highlightId)")!, method: "DELETE"))
    }

    // MARK: - Summarize jobs

    /// GET /books/:id/status — summarize/index progress.
    static func status(bookId: Int) async throws -> SummaryStatus {
        let data = try await run(authed(URL(string: "\(base)/books/\(bookId)/status")!))
        return try decode(SummaryStatus.self, from: data, context: "status")
    }

    /// POST /books/:id/summarize — kick off summarizing missing chapters.
    /// Returns 202 `{status:"started",pid}` (async) — poll `status` for progress.
    static func summarize(bookId: Int) async throws {
        _ = try await run(authed(URL(string: "\(base)/books/\(bookId)/summarize")!, method: "POST"))
    }

    /// POST /books/:id/extract — extract chapters from the EPUB (prerequisite for
    /// summarizing a book that has no chapters yet).
    static func extract(bookId: Int) async throws {
        _ = try await run(authed(URL(string: "\(base)/books/\(bookId)/extract")!, method: "POST"))
    }
}
