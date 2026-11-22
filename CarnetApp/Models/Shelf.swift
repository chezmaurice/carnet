import Foundation

// MARK: - The shelf (one list of entries, every kind)
//
// Shapes are the server's (`GET /garden/entries?view=shelf` and
// `GET /garden/entries/:collection/:locale/:slug`,
// maurice/server/data-api/services/gardenShelf.ts). An entry is one subject
// with up to three parts: the *source* to read (a Calibre book, an article's
// captured text), *mine* (the working side: notes, highlights, résonances)
// and *shared* (what the member wrote to be read, a draft until published).

/// The kinds the list groups by. `posts` covers blog and essays.
enum ShelfKind: String, Codable, CaseIterable, Identifiable {
    case books, articles, movies, series, music, podcasts, games, posts
    var id: String { rawValue }

    /// Albums and podcasts come in square sleeves; the rest stand upright.
    var squareCover: Bool { self == .music || self == .podcasts }

    var label: String {
        switch self {
        case .books: return "Books"
        case .articles: return "Articles"
        case .movies: return "Films"
        case .series: return "Series"
        case .music: return "Music"
        case .podcasts: return "Podcasts"
        case .games: return "Games"
        case .posts: return "Posts"
        }
    }

    /// The word a row and a page open their byline with.
    var singular: String {
        switch self {
        case .books: return "Book"
        case .articles: return "Article"
        case .movies: return "Film"
        case .series: return "Series"
        case .music: return "Album"
        case .podcasts: return "Podcast"
        case .games: return "Game"
        case .posts: return "Post"
        }
    }
}

/// What there is to read: a book of the library or an article's capture.
struct ShelfSource: Codable, Hashable {
    struct Progress: Codable, Hashable {
        let chapterSlug: String
        let chapterTitle: String?
        /// Position of the chapter among the book's chapters, 0–1.
        let fraction: Double
        let finished: Bool
        let tracking: Bool
        let updatedAt: String

        enum CodingKeys: String, CodingKey {
            case fraction, finished, tracking
            case chapterSlug = "chapter_slug"
            case chapterTitle = "chapter_title"
            case updatedAt = "updated_at"
        }
    }

    /// "book" or "article".
    let type: String
    // book
    let bookId: Int?
    let chapters: Int?
    let progress: Progress?
    // article
    let url: String?
    /// False for a bookmark: the site refused the capture, only the link was kept.
    let captured: Bool?
    let wordCount: Int?
    let readingMinutes: Int?
    /// The article's summary, written to be read in its place — in the list
    /// as on the entry's page, so it is there offline. `current` is false for
    /// one written before summaries carried the substance: the page asks for
    /// it again.
    let summary: Summary?
    /// Who gave this article: it is the reader's own copy of an article
    /// another member shared with them.
    var sharedBy: SharedBy? = nil

    /// `text` is the essence, a paragraph; `long` the summary meant to be read
    /// instead of the article ("" until written).
    struct Summary: Codable, Hashable {
        let text: String
        let long: String?
        let current: Bool
    }

    enum CodingKeys: String, CodingKey {
        case type, chapters, progress, url, captured, summary
        case sharedBy = "shared_by"
        case bookId = "book_id"
        case wordCount = "word_count"
        case readingMinutes = "reading_minutes"
    }

    var isBook: Bool { type == "book" }
    var isReadable: Bool { isBook || (captured ?? false) }
}

enum SharedState: String, Codable, Hashable {
    case draft, published
    var mark: EntryState { self == .draft ? .draft : .published }
}

/// A member of the household, as an entry names them: its owner, who it is
/// shared with, who wrote a note on it.
/// The member an article was copied from (`shared_by`): a member brief, or
/// the username alone when that member is no longer in the household.
struct SharedBy: Codable, Hashable {
    let username: String
    let displayName: String?
    let avatarColor: String?
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case username
        case displayName = "display_name"
        case avatarColor = "avatar_color"
        case avatarUrl = "avatar_url"
    }

    var name: String { displayName ?? username }
    /// « Shared by Candide », in the member's language.
    var line: String { L("article.shared_by", name) }
}

struct MemberBrief: Codable, Hashable, Identifiable {
    let id: String
    let username: String
    let displayName: String
    let avatarColor: String
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case avatarColor = "avatar_color"
        case avatarUrl = "avatar_url"
    }

    /// The same person as the session knows its members — what `MemberBadge` draws.
    var member: CarnetAPI.Member {
        CarnetAPI.Member(id: id, display_name: displayName, avatar_color: avatarColor, has_pin: false, role: nil,
                         avatar_url: avatarUrl)
    }
}

struct ShelfEntry: Codable, Identifiable, Hashable {
    struct Mine: Codable, Hashable {
        let notes: Int
        let opened: Bool
    }
    struct Shared: Codable, Hashable {
        let state: SharedState
    }
    struct Translation: Codable, Hashable {
        let id: String
        let locale: String
        let shared: Shared?
    }

    /// `<collection>/<locale>/<slug>`, or `calibre/<id>` for a book of the
    /// library nothing is written on yet.
    let id: String
    let kind: ShelfKind
    let collection: String?
    let locale: String?
    let slug: String?
    let title: String
    let byline: String?
    let date: String
    let updatedAt: String
    let image: String?
    let tags: [String]
    let rating: Int?
    let status: String?
    let source: ShelfSource?
    let mine: Mine?
    let shared: Shared?
    /// Put away from the list. Absent from a server that does not archive yet.
    let archived: Bool?
    let translations: [Translation]
    /// Whose entry it is, when it is another member's, shared with this one.
    /// Nil for the member's own. Absent from a server that does not share yet.
    let owner: MemberBrief?
    /// The members it is shared with; the owner is not one.
    let participants: [MemberBrief]?

    enum CodingKeys: String, CodingKey {
        case id, kind, collection, locale, slug, title, byline, date, image, tags, rating, status
        case source, mine, shared, archived, translations, owner, participants
        case updatedAt = "updated_at"
    }

    /// True for a book of the library with no entry in the garden: there is
    /// no page to fetch, the row is everything there is.
    var isLibraryOnly: Bool { collection == nil }
    var coverLetter: String { String(title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased() }
    var coverURL: URL? { gardenImageURL(image) }
    /// "Book · Gaspard Kœnig"
    var kindLine: String { [kind.singular, byline].compactMap { $0 }.joined(separator: " · ") }
    /// Nothing of the member's on either side.
    var isUntouched: Bool { shared == nil && (mine == nil || (!mine!.opened && mine!.notes == 0)) }
    var noteCount: Int { mine?.notes ?? 0 }
    /// Another member's entry, read here because they shared it.
    var isForeign: Bool { owner != nil }
    /// Everyone on the entry but the reader's own side of it: the owner
    /// first when it is someone else's, then the members it is shared with.
    var people: [MemberBrief] { (owner.map { [$0] } ?? []) + (participants ?? []) }
    /// More than one person writes here.
    var isShared: Bool { !people.isEmpty }
}

/// One element that may not decode: a kind this build has never heard of.
private struct Lossy<T: Codable>: Codable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    func encode(to encoder: Encoder) throws { try value?.encode(to: encoder) }
}

struct ShelfResponse: Codable {
    struct Garden: Codable {
        let username: String
        let site: String?
    }
    struct KindCount: Codable, Hashable {
        let kind: ShelfKind
        let count: Int
    }
    let garden: Garden
    let kinds: [KindCount]
    let entries: [ShelfEntry]

    enum CodingKeys: String, CodingKey { case garden, kinds, entries }

    /// The garden grows collections faster than the app ships: an entry or a
    /// count of a kind unknown here is left out, rather than failing the list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        garden = try c.decode(Garden.self, forKey: .garden)
        kinds = try c.decode([Lossy<KindCount>].self, forKey: .kinds).compactMap(\.value)
        entries = try c.decode([Lossy<ShelfEntry>].self, forKey: .entries).compactMap(\.value)
    }
}

// MARK: - One entry, both faces in full

/// One thing on the member's side: a dated note, a quote, a résonance, a
/// passage highlighted while reading, or a fragment Maurice filed.
struct MineItem: Codable, Hashable, Identifiable {
    struct Place: Codable, Hashable {
        let page: String?
        let chapterSlug: String?
        let chapterTitle: String?
        let view: String?

        enum CodingKeys: String, CodingKey {
            case page, view
            case chapterSlug = "chapter_slug"
            case chapterTitle = "chapter_title"
        }
    }
    struct Origin: Codable, Hashable {
        let label: String
        let entryId: String?
        let publishedUrl: String?

        enum CodingKeys: String, CodingKey {
            case label
            case entryId = "entry_id"
            case publishedUrl = "published_url"
        }
    }

    /// note | quote | resonance | highlight | fragment
    let kind: String
    let serverId: String?
    let date: String?
    let text: String?
    let quote: String?
    let summary: String?
    let place: Place?
    let from: Origin?
    /// Who wrote it. Absent from a server that does not share entries yet.
    let author: MemberBrief?
    /// The exchange with Maurice a note was kept from, and who started it.
    let conversation: Exchange?
    /// Whether the member may rewrite it, or take it off (an owner may take
    /// off what someone else signed on their shared entry, not rewrite it).
    /// Absent from a server that cannot edit notes: nothing is offered then.
    let editable: Bool?
    let deletable: Bool?
    /// The day it was last rewritten ("YYYY-MM-DD"), or nil.
    let edited: String?

    var canEdit: Bool { editable == true && serverId != nil }
    var canDelete: Bool { deletable == true && serverId != nil }

    struct Exchange: Codable, Hashable {
        let id: String
        let initiator: MemberBrief?
    }

    enum CodingKeys: String, CodingKey {
        case kind, date, text, quote, summary, from, author, conversation, editable, deletable, edited
        case serverId = "id"
        case place = "where"
    }

    /// Notes carry no id of their own (they are lines of a markdown file).
    /// Two members may write the same words on the same day: the author is part of it.
    var id: String { serverId ?? "\(kind)|\(date ?? "")|\(author?.id ?? "")|\(quote ?? "")|\(text ?? "")" }
}

struct EntryDetail: Codable, Hashable {
    struct Mine: Codable, Hashable {
        let notes: Int
        let opened: Bool
        let webPath: String?
        let file: String
        let prose: String
        let items: [MineItem]

        enum CodingKeys: String, CodingKey {
            case notes, opened, file, prose, items
            case webPath = "web_path"
        }
    }
    struct Link: Codable, Hashable {
        let basename: String
        let label: String
        let entryId: String?
        let publishedUrl: String?

        enum CodingKeys: String, CodingKey {
            case basename, label
            case entryId = "entry_id"
            case publishedUrl = "published_url"
        }
    }
    struct Shared: Codable, Hashable {
        let state: SharedState
        let webPath: String?
        let file: String
        let publicUrl: String?
        let title: String?
        let body: String
        let links: [Link]

        enum CodingKeys: String, CodingKey {
            case state, file, title, body, links
            case webPath = "web_path"
            case publicUrl = "public_url"
        }
    }

    let mine: Mine?
    let shared: Shared?
}

// MARK: - Every note

/// One thing the member wrote, with the entry it is on
/// (`GET /garden/entries?view=notes`): a note, a quote, a résonance, or a
/// highlight written under.
struct FeedNote: Decodable, Hashable, Identifiable {
    let entryId: String
    let item: MineItem

    private enum CodingKeys: String, CodingKey { case entryId = "entry_id" }

    init(from decoder: Decoder) throws {
        entryId = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .entryId)
        item = try MineItem(from: decoder)
    }

    var id: String { "\(entryId)|\(item.id)" }
}

/// The notes, newest first, and the rows of the entries they are on.
struct NotesResponse: Decodable {
    let entries: [ShelfEntry]
    let notes: [FeedNote]

    private enum CodingKeys: String, CodingKey { case entries, notes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decode([Lossy<ShelfEntry>].self, forKey: .entries).compactMap(\.value)
        notes = try c.decode([FeedNote].self, forKey: .notes)
    }
}

// MARK: - The site deploy

/// Where the member's site stands after a publish: one deploy runs at a time,
/// a few seconds each (`GET /garden/site/deploy`).
struct DeployState: Codable, Hashable {
    /// idle | queued | running | failed
    let status: String
    let error: String?

    var inProgress: Bool { status == "running" || status == "queued" }
    var failed: Bool { status == "failed" }
}

// MARK: - Conversations about an entry

/// A conversation with Maurice about an entry — held from its page, or in the
/// Maurice app with its fiche in context (`GET …/conversations`). Its summary
/// is what the fiche keeps of it, when the member asked to see it.
struct EntryConversation: Codable, Hashable, Identifiable {
    struct Summary: Codable, Hashable {
        let id: String
        let text: String
        let writtenAt: String?
        /// The conversation went on after the summary was written.
        let stale: Bool

        enum CodingKeys: String, CodingKey {
            case id, text, stale
            case writtenAt = "written_at"
        }
    }
    struct Persona: Codable, Hashable {
        let id: String
        let name: String
    }

    let id: String
    let title: String?
    let createdAt: String
    let updatedAt: String
    let messageCount: Int
    /// "entry" — held from the entry's page; "linked" — linked to it from the Maurice app.
    let via: String
    let maurice: Persona?
    let summary: Summary?

    enum CodingKeys: String, CodingKey {
        case id, title, via, maurice, summary
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case messageCount = "message_count"
    }

    /// "Today", "Yesterday", or the day — the server's times are UTC.
    var when: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = f.date(from: updatedAt) ?? ISO8601DateFormatter().date(from: updatedAt) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return cal.isDate(date, equalTo: .now, toGranularity: .year)
            ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    var displayTitle: String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled conversation" : t
    }
}
