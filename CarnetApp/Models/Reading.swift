import Foundation

// MARK: - Reading models (Calibre)
//
// Shapes are the authoritative ones from the Maurice server data-api
// (maurice/server/data-api/routes/calibre/** + services/{calibre,bookmarks}.ts),
// verified against the live library. Casing matches the server: the books/
// chapters endpoints return camelCase; bookmarks/reading-progress return
// snake_case. Each model maps its own keys.

/// A book in the Calibre library. `/books` returns count fields inline
/// (chapters / summarized / indexed); `/books/:id/metadata` adds description
/// but omits the counts.
struct Book: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    let authors: [String]
    let tags: [String]?
    let formats: [String]?
    let series: String?
    let description: String?
    /// Total extracted chapters (0 / nil when the book hasn't been extracted).
    let chapters: Int?
    /// How many chapters have an AI summary.
    let summarized: Int?
    /// How many summaries are indexed to the vector store.
    let indexed: Int?
    /// When Calibre took the book in, ISO-8601. Optional: older cached lists
    /// and the search endpoint don't carry it.
    let added: String?

    var author: String { authors.isEmpty ? "Unknown" : authors.joined(separator: ", ") }
    /// First letter for the placeholder cover.
    var coverLetter: String { String(title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased() }

    /// `added` as a date, for sorting. Parsed on demand — the list decoder
    /// stays a plain JSONDecoder, and a cached list written by an earlier
    /// build simply has no date.
    var addedDate: Date? {
        guard let added else { return nil }
        return Book.isoParser.date(from: added) ?? Book.isoParserNoFraction.date(from: added)
    }
    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoParserNoFraction = ISO8601DateFormatter()

    var chapterCount: Int { chapters ?? 0 }
    var summarizedCount: Int { summarized ?? 0 }
    var hasChapters: Bool { chapterCount > 0 }
    /// Fraction of chapters that carry a summary (the library's progress axis —
    /// reading position is per-member and not exposed on the list endpoint).
    var summarizedFraction: Double? {
        guard chapterCount > 0 else { return nil }
        return Double(summarizedCount) / Double(chapterCount)
    }
    var isFullySummarized: Bool { hasChapters && summarizedCount >= chapterCount }
}

/// One chapter in a book's table of contents (`/books/:id/chapters`).
struct Chapter: Codable, Identifiable, Hashable {
    let index: Int
    let slug: String
    let title: String
    let wordCount: Int?
    let summaryWordCount: Int?
    let hasSummary: Bool

    var id: String { slug }

    /// Estimated reading minutes (~230 wpm), preferring the summary length.
    var readingMinutes: Int {
        let words = summaryWordCount ?? wordCount ?? 0
        return max(1, Int((Double(words) / 230.0).rounded()))
    }
}

/// Full chapter text (`/books/:id/chapters/by-slug/:slug`).
struct ChapterText: Codable, Hashable {
    let title: String
    let text: String
    let wordCount: Int?
}

/// A chapter's AI summary (`/books/:id/chapters/by-slug/:slug/summary`).
struct ChapterSummary: Codable, Hashable {
    let exists: Bool
    let title: String?
    let summary: String?
}

/// The reader's resume point for a book, per member.
/// GET returns `null` when the book hasn't been opened / tracking is off.
struct ReadingProgress: Codable, Hashable {
    let bookId: Int?
    let chapterIndex: Int?
    let chapterSlug: String?
    let view: String?      // "full" | "summary"
    let enabled: Int?      // 0/1 from the server (SQLite integer)
    /// Fractional scroll position (0–1) within the current chapter+view.
    let position: Double?
    /// Server timestamp of the last update — used to reconcile with the local copy.
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case view, enabled, position
        case bookId = "book_id"
        case chapterIndex = "chapter_index"
        case chapterSlug = "chapter_slug"
        case updatedAt = "updated_at"
    }

    var isSummary: Bool { view == "summary" }
}

/// A chapter-level bookmark, optionally carrying a note. (v1 stands in for the
/// design's passage-level highlights until a range-annotation backend exists.)
struct Bookmark: Codable, Identifiable, Hashable {
    let id: Int
    let bookId: Int?
    let chapterSlug: String
    let view: String
    let note: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, view, note
        case bookId = "book_id"
        case chapterSlug = "chapter_slug"
        case createdAt = "created_at"
    }
}

/// Response from POST on a bookmark toggle (`{ bookmarked, bookmark? }`).
struct BookmarkToggleResponse: Codable {
    let bookmarked: Bool
    let bookmark: Bookmark?
}

/// A passage-level highlight — a quoted range in a chapter, with an optional
/// note and a colour. `startOffset`/`endOffset` index the chapter's plain text.
struct Highlight: Codable, Identifiable, Hashable {
    let id: Int
    let bookId: Int?
    let chapterSlug: String
    let quote: String
    let note: String?
    let color: String
    let startOffset: Int?
    let endOffset: Int?
    /// Which of the chapter's two texts the offsets point into: "full" or
    /// "summary". Optional so a response from a server that predates the column
    /// still decodes; absent means the full text, which is all there was.
    let view: String?
    let createdAt: String?
    /// The conversation with Maurice opened from this passage, and what it
    /// came to once that is written. Only the list sends it; a create or an
    /// update answers the id alone.
    var conversationId: String? = nil
    var conversation: HighlightConversation? = nil

    enum CodingKeys: String, CodingKey {
        case id, quote, note, color, view, conversation
        case conversationId = "conversation_id"
        case bookId = "book_id"
        case chapterSlug = "chapter_slug"
        case startOffset = "start_offset"
        case endOffset = "end_offset"
        case createdAt = "created_at"
    }

    /// The reader mode this highlight belongs to.
    var readerView: String { view ?? "full" }
}

/// A passage's conversation with Maurice: its title, and its summary — the
/// same one the book's fiche carries — once the conversation has settled.
struct HighlightConversation: Codable, Hashable {
    let id: String
    let title: String?
    let summary: String?
}

/// The highlight palette — an intentional exception to the monochrome system
/// (like per-member avatar colour). Keys are stored server-side.
enum HighlightColor: String, CaseIterable, Identifiable {
    case yellow, green, pink, blue
    var id: String { rawValue }
}

/// Summarize/index counts for a book (`/books/:id/status`).
struct SummaryStatus: Codable, Hashable {
    let chapters: Int?
    let summarized: Int?
    let indexed: Int?
    /// Outcome of the last async action (extract/summarize), if one has run.
    let job: JobInfo?

    var isComplete: Bool {
        guard let total = chapters, total > 0, let done = summarized else { return false }
        return done >= total
    }
}

/// Last outcome of a fire-and-forget calibre action, surfaced so the app can
/// show a real error instead of spinning forever.
struct JobInfo: Codable, Hashable {
    enum State: String, Codable { case running, ok, error }
    let action: String
    let state: State
    let error: String?
    let at: String?
}
