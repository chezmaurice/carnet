import Foundation

// MARK: - Domains (what Maurice keeps on the member)
//
// A *domain* is a part of the member's life Maurice follows, with a *brief*
// he keeps on it — his working memory on that domain, made visible: written
// at night, read in every private conversation, corrected or erased by the
// member. A *reading companion* is the other kind of row: one book followed
// at the reading position, with a pinned conversation, and no brief.
//
// Shapes are those of `GET /api/domains` and `GET/PUT /api/domains/:id/brief`
// (maurice/server/src/routes/domains.ts). The server speaks snake_case here.

/// One line of `GET /api/domains`'s `domains` array.
struct DomainSummary: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let tagline: String?
    let kind: String?
    /// False for a domain granted to a guest: the brief is the creator's.
    let mine: Bool?
    let count: Int?
    let brief: BriefStamp?

    /// When the brief was last rewritten and by whom — enough for a row.
    struct BriefStamp: Codable, Hashable {
        let updated_at: String
        let model: String?
        let sources: Int?
        var byMember: Bool { model == "member" }
    }

    var isMine: Bool { mine ?? true }
}

/// One line of `GET /api/domains`'s `companions` array.
struct CompanionSummary: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let tagline: String?
    let mine: Bool?
    /// The book the companion follows. The server sends the id as the
    /// composer stored it — a number for a Calibre book.
    let book_id: BookRef?
    /// The pinned conversation: the most recently touched one bound to the
    /// companion that the member sits in, or nil when none exists yet.
    let conversation_id: String?

    /// Calibre's numeric id, when the ref is one.
    var bookId: Int? { book_id?.intValue }

    enum BookRef: Codable, Hashable {
        case int(Int), string(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .int(i); return }
            self = .string(try c.decode(String.self))
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .int(let i): try c.encode(i)
            case .string(let s): try c.encode(s)
            }
        }
        var intValue: Int? {
            switch self {
            case .int(let i): return i
            case .string(let s): return Int(s)
            }
        }
    }
}

struct DomainsOverview: Codable {
    let domains: [DomainSummary]
    let companions: [CompanionSummary]
}

/// The brief as `GET /api/domains/:id/brief` returns it.
struct DomainBrief: Codable, Hashable {
    let text: String
    /// Server time, "YYYY-MM-DD HH:MM:SS" (UTC) — see `ServerDate`.
    let updated_at: String
    /// The conversations the last rewrite read.
    let sources: [String]?
    let read_until: String?
    /// The night's model, or "member" once the member rewrote it by hand.
    let model: String?

    var byMember: Bool { model == "member" }
    var sourceCount: Int { sources?.count ?? 0 }
}

/// `GET /api/domains/:id/brief`: the domain's name rides along, the brief
/// is nil when the night has not written one yet.
struct BriefResponse: Codable {
    struct Head: Codable { let id: String; let name: String; let tagline: String? }
    let domain: Head
    let brief: DomainBrief?
}

/// What `POST /api/domains/:id/brief/refresh` said happened.
enum BriefRefreshOutcome: Equatable {
    case written(sources: Int)
    /// Nothing new touched the domain: no model call was made.
    case unchanged
    /// The night's allowance is spent (429).
    case capped
    case failed(String)
}

// MARK: - Conversations Maurice opened

/// One row of `GET /api/conversations`, reduced to what Carnet shows: Carnet
/// has no chat, so the list only cares for the conversations Maurice opened
/// on his own (`opened_by = "maurice"`) and whether they were read.
struct ConversationRow: Codable, Identifiable, Hashable {
    let id: String
    let title: String?
    let opened_by: String?
    let unread: Bool?
    let created_at: String?
    let updated_at: String?
    let last_message_at: String?
    let message_count: Int?

    var openedByMaurice: Bool { opened_by == "maurice" }
    var isUnread: Bool { unread ?? false }
}

/// `GET /api/conversations/:id` — the thread, read here, answered in the
/// Maurice app.
struct ConversationDetail: Codable {
    let id: String
    let title: String?
    let opened_by: String?
    let created_at: String?
    let messages: [ConversationMessage]
}

struct ConversationMessage: Codable, Identifiable, Hashable {
    let id: String
    let role: String
    let content: String
    let created_at: String?
    let author_id: String?

    var isMaurice: Bool { role == "assistant" }
}

// MARK: - Server dates

/// The server writes SQLite's `datetime('now')` — "YYYY-MM-DD HH:MM:SS" in
/// UTC — on most rows, and ISO-8601 on a few. One parser for both, and the
/// short relative age the rows show ("today", "3d", "2w").
enum ServerDate {
    private static let sqlite: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return sqlite.date(from: s) ?? iso.date(from: s) ?? isoPlain.date(from: s)
    }

    /// "today", "1d", "3d", "2w", "4mo", "1y" — the age a row shows.
    static func age(_ s: String?, now: Date = Date()) -> String {
        guard let d = parse(s) else { return "" }
        let days = Int(now.timeIntervalSince(d) / 86_400)
        if days < 1 { return "today" }
        if days < 14 { return "\(days)d" }
        if days < 60 { return "\(days / 7)w" }
        if days < 365 { return "\(days / 30)mo" }
        return "\(days / 365)y"
    }

    /// "19 Sept 2026, 16:28" in the device's locale.
    static func absolute(_ s: String?) -> String {
        guard let d = parse(s) else { return s ?? "" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}
