import Foundation

// MARK: - Article models (garden)

/// Where to fetch a garden entry's cover art — an article's lead image, a
/// book's or a film's poster. The garden serves it under
/// `/images/<member>/resources/…`, but that path is behind the site's session
/// and carries no token from here; the server mirrors it, open, at
/// `/api/garden-images/<member>/…` — rooted at `resources` only, since the
/// sibling `images/notes` holds the illustrations of private notes.
///
/// Nil when there is none, which is normal: a bookmark the site refused to let
/// us capture has no lead image, and plenty of entries never had one. The row
/// keeps its lettered placeholder.
func gardenImageURL(_ sitePath: String?) -> URL? {
    guard let sitePath, sitePath.hasPrefix("/images/") else { return nil }
    let parts = sitePath.dropFirst("/images/".count).split(separator: "/", maxSplits: 1)
    guard parts.count == 2, parts[1].hasPrefix("resources/") else { return nil }
    let member = parts[0]
    let rest = parts[1].dropFirst("resources/".count)
    return URL(string: "\(CarnetAPI.baseURL)/api/garden-images/\(member)/\(rest)")
}
//
// Shapes are the authoritative ones from the Maurice server data-api
// (maurice/server/data-api/routes/garden-articles.ts +
// services/gardenArticles.ts). The garden speaks snake_case throughout.

/// A saved article — one fiche in the member's garden (`GET /garden/articles`).
struct Article: Codable, Identifiable, Hashable {
    let slug: String
    let locale: String
    let title: String
    /// Original page URL — what "Open in browser" opens.
    let url: String?
    let savedAt: String?
    let subtitle: String?
    let author: String?
    let publication: String?
    let publishedAt: String?
    /// Site-relative cover path (e.g. /images/<member>/resources/articles/…).
    let image: String?
    let excerpt: String?
    let summary: String?
    /// The long summary, meant to be read instead of the article — what the
    /// reader's Summary view shows when there is one.
    let summaryLong: String?
    let tags: [String]?
    let wordCount: Int?
    /// The server captured the page — its text is readable in the app.
    let hasText: Bool?
    /// Changes when the server's text does (a cleanup, a second capture), so
    /// the copy kept on the device is known to be stale.
    let textRev: String?
    /// Saved as a bookmark only: the site refused the capture.
    let needsCapture: Bool?
    /// Why the capture failed, verbatim from the save (e.g. a 403).
    let captureError: String?
    /// ios-share | chrome | mcp — which surface saved it.
    let sourceClient: String?
    let highlightCount: Int?
    /// False until the member has written on it (a note, a resonance, a
    /// highlight with a note). A bare share writes an *unopened* fiche: kept
    /// and readable, but not yet one of their fiches. Absent means opened.
    let opened: Bool?
    let ficheWebPath: String?
    let cardWebPath: String?
    /// Who gave it: the member's own copy of an article shared with them.
    var sharedBy: SharedBy? = nil
    /// The username whose notes hold it, for an article given from another
    /// household and shared live with the member (`@<owner>/articles/…` on
    /// the shelf): its text is read with `?owner=`. Nil for the member's own.
    /// Not part of what the server sends.
    var owner: String? = nil

    enum CodingKeys: String, CodingKey {
        case slug, locale, title, url, subtitle, author, publication, image, excerpt, summary, tags, opened
        case sharedBy = "shared_by"
        case summaryLong = "summary_long"
        case savedAt = "saved_at"
        case publishedAt = "published_at"
        case wordCount = "word_count"
        case hasText = "has_text"
        case textRev = "text_rev"
        case needsCapture = "needs_capture"
        case captureError = "capture_error"
        case sourceClient = "source_client"
        case highlightCount = "highlight_count"
        case ficheWebPath = "fiche_web_path"
        case cardWebPath = "card_web_path"
    }

    /// Stable identity across locales (two locales may share a slug).
    var id: String { "\(owner.map { "@\($0)/" } ?? "")\(locale)/\(slug)" }
    var readable: Bool { hasText ?? false }
    var isBookmarkOnly: Bool { needsCapture ?? false }
    var isOpened: Bool { opened ?? true }
    var hasSummary: Bool { !readableSummary.isEmpty }
    /// What the reader's Summary view reads: the long one, else the paragraph.
    var readableSummary: String {
        let long = (summaryLong ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return long.isEmpty ? (summary ?? "") : long
    }
    /// First letter for the placeholder cover.
    var coverLetter: String { String(title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased() }

    /// Where to fetch `image`. The garden serves its cover art under
    /// `/images/<member>/resources/…`, but that path is behind the site's
    /// session and carries no token from here; the server mirrors it, open, at
    /// `/api/garden-images/<member>/…` — rooted at `resources` only, since the
    /// sibling `images/notes` holds the illustrations of private notes.
    ///
    /// Nil when the save captured no lead image, which is normal: a bookmark
    /// the site refused has nothing to capture. The row keeps its letter.
    var coverURL: URL? { gardenImageURL(image) }
    /// Estimated reading minutes (~230 wpm), same convention as chapters.
    var readingMinutes: Int { max(1, Int((Double(wordCount ?? 0) / 230.0).rounded())) }
    /// "Publication · date" line for rows.
    var bylineShort: String {
        [publication, publishedAt ?? savedAt].compactMap { $0 }.joined(separator: " · ")
    }
}

/// `GET /garden/articles/:slug` — the list shape plus the fiche's markdown
/// body (the lead quote and the comment history).
struct ArticleDetail: Codable, Hashable {
    let article: Article
    let body: String

    init(from decoder: Decoder) throws {
        article = try Article(from: decoder)
        let c = try decoder.container(keyedBy: BodyKey.self)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
    }
    init(article: Article, body: String) {
        self.article = article
        self.body = body
    }
    func encode(to encoder: Encoder) throws {
        try article.encode(to: encoder)
        var c = encoder.container(keyedBy: BodyKey.self)
        try c.encode(body, forKey: .body)
    }
    private enum BodyKey: String, CodingKey { case body }
}

/// `GET /garden/articles/:slug/text` — the captured full text.
struct ArticleText: Codable, Hashable {
    let slug: String
    let locale: String
    let title: String?
    let text: String
    /// What the page set apart, as ranges in `text`. Absent from a server
    /// that does not keep them, and for a text captured before it did.
    let styles: [TextStyle]?
}

/// A stretch of a reading text the page set apart: a heading inside the
/// article, bold (an interview's questions), italic. `start`/`end` index the
/// plain text in UTF-16 units, like a highlight's offsets.
struct TextStyle: Codable, Hashable {
    let start: Int
    let end: Int
    /// "heading" | "strong" | "em"
    let kind: String
}

// MARK: - Garden entries

/// One face of a garden entry — where the site renders it, and its
/// repo-relative file for editors holding the garden checkout.
struct GardenEntryFace: Codable, Hashable {
    let webPath: String?
    let file: String

    enum CodingKeys: String, CodingKey {
        case file
        case webPath = "web_path"
    }
}

/// One subject in the garden: a published card, a working fiche, or both
/// (`GET /garden/entries`).
struct GardenEntry: Codable, Identifiable, Hashable {
    let collection: String
    let locale: String
    let slug: String
    let title: String
    /// The subject's own date, from the frontmatter.
    let date: String
    /// Newest file mtime across the entry's faces, ISO-8601 — when it was last
    /// written on. Optional: a cached list from a build that predates it, and
    /// the older servers that don't send it, simply have none.
    let updatedAt: String?
    let tags: [String]
    let image: String?
    let card: GardenEntryFace?
    let fiche: GardenEntryFace?
    /// False when the entry is nothing but an unopened fiche (an article share
    /// nobody has written on). Absent means opened.
    let opened: Bool?

    enum CodingKeys: String, CodingKey {
        case collection, locale, slug, title, date, tags, image, card, fiche, opened
        case updatedAt = "updated_at"
    }

    var id: String { "\(collection)/\(locale)/\(slug)" }
    var isOpened: Bool { opened ?? true }
    /// `updatedAt` as a date, for sorting. Parsed on demand, so the list keeps
    /// decoding with a plain JSONDecoder.
    var updatedDate: Date? {
        guard let updatedAt else { return nil }
        return GardenEntry.isoFractional.date(from: updatedAt)
            ?? GardenEntry.isoPlain.date(from: updatedAt)
    }
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    var coverLetter: String { String(title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased() }
    /// Same mapping as an article's — see `gardenImageURL`.
    var coverURL: URL? { gardenImageURL(image) }
}

struct GardenEntriesResponse: Codable {
    struct Garden: Codable {
        let username: String
        let collections: [String]
    }
    let garden: Garden
    let entries: [GardenEntry]
}

// MARK: - Résonances (wiki-links)

/// One autocomplete hit for "link this to…" (`GET /garden/links/targets`).
struct LinkTarget: Codable, Identifiable, Hashable {
    let collection: String
    let locale: String
    let slug: String
    let title: String
    let date: String
    /// The basename a [[wiki-link]] to this target uses (fiche when it has one).
    let linkBasename: String
    let hasFiche: Bool

    enum CodingKeys: String, CodingKey {
        case collection, locale, slug, title, date
        case linkBasename = "link_basename"
        case hasFiche = "has_fiche"
    }

    var id: String { "\(collection)/\(locale)/\(slug)" }
}

/// Display metadata for the collections the Garden section filters by.
enum GardenCollection: String, CaseIterable, Identifiable {
    case articles, books, movies, series, podcasts, games, people, blog, essays, notes, pages
    var id: String { rawValue }

    var label: String {
        switch self {
        case .articles: return "Articles"
        case .books: return "Books"
        case .movies: return "Movies"
        case .series: return "Series"
        case .podcasts: return "Podcasts"
        case .games: return "Games"
        case .people: return "People"
        case .blog: return "Blog"
        case .essays: return "Essays"
        case .notes: return "Notes"
        case .pages: return "Pages"
        }
    }

    var symbol: String {
        switch self {
        case .articles: return "doc.text"
        case .books: return "book"
        case .movies: return "film"
        case .series: return "tv"
        case .podcasts: return "waveform"
        case .games: return "gamecontroller"
        case .people: return "person"
        case .blog: return "pencil.line"
        case .essays: return "text.alignleft"
        case .notes: return "note.text"
        case .pages: return "doc"
        }
    }
}

extension Article {
    /// An article read in its owner's notes — given from another household
    /// and shared live with the member — made from its shelf row: the
    /// article's own page (`GET …/articles/:slug`) is the owner's, not theirs.
    static func shared(_ entry: ShelfEntry) -> Article {
        var row: [String: Any] = [
            "slug": entry.slug ?? "",
            "locale": entry.locale ?? "",
            "title": entry.title,
            "has_text": entry.source?.captured ?? true,
        ]
        if let url = entry.source?.url { row["url"] = url }
        if let byline = entry.byline { row["author"] = byline }
        if let summary = entry.source?.summary {
            row["summary"] = summary.text
            if let long = summary.long { row["summary_long"] = long }
        }
        let data = (try? JSONSerialization.data(withJSONObject: row)) ?? Data("{}".utf8)
        var article = (try? JSONDecoder().decode(Article.self, from: data))
            ?? (try! JSONDecoder().decode(Article.self, from: Data(#"{"slug":"","locale":"","title":""}"#.utf8)))
        article.owner = entry.owner?.username
        return article
    }
}
