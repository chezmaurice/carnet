import Foundation
import CryptoKit

/// On-device record of where the reader last left off in each book — chapter,
/// view and fractional scroll position. Written immediately as you read so
/// resume works offline; the reader also pushes it to the server (best-effort)
/// and reconciles with the synced copy by timestamp when back online.
///
/// Kept per member of each household (MemberStore): a position is the
/// reader's, not the household's.
enum ReadingPositionStore {
    struct Record: Codable, Equatable {
        var chapterIndex: Int
        var chapterSlug: String
        var lastView: String      // which view to resume: "full" | "summary"
        var fullChar: Int = 0     // top visible character index in the full text
        var summaryPara: Int = 0  // top visible paragraph index in the summary
        var updatedAt: Date       // client clock — for local-vs-server reconciliation

        // Defaults keep records written by earlier builds decodable.
        private enum CodingKeys: String, CodingKey {
            case chapterIndex, chapterSlug, lastView, fullChar, summaryPara, updatedAt
        }
        init(chapterIndex: Int, chapterSlug: String, lastView: String,
             fullChar: Int = 0, summaryPara: Int = 0, updatedAt: Date) {
            self.chapterIndex = chapterIndex; self.chapterSlug = chapterSlug
            self.lastView = lastView; self.fullChar = fullChar
            self.summaryPara = summaryPara; self.updatedAt = updatedAt
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            chapterIndex = try c.decode(Int.self, forKey: .chapterIndex)
            chapterSlug = try c.decode(String.self, forKey: .chapterSlug)
            lastView = try c.decode(String.self, forKey: .lastView)
            fullChar = try c.decodeIfPresent(Int.self, forKey: .fullChar) ?? 0
            summaryPara = try c.decodeIfPresent(Int.self, forKey: .summaryPara) ?? 0
            updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        }
    }

    /// The signed-in member's positions; nil when no one is signed in.
    static func fileURL() -> URL? { MemberStore.file("positions.json") }

    private static func loadAll() -> [String: Record] {
        guard let url = fileURL(), let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: Record].self, from: data) else { return [:] }
        return dict
    }

    static func get(bookId: Int) -> Record? { loadAll()["\(bookId)"] }

    /// Book id → when the reader last left off in it. One file read for the
    /// whole library, so a list can sort by it without re-reading per row.
    /// Article keys (`article:…`) are skipped: they aren't book ids.
    static func lastOpenedByBook() -> [Int: Date] {
        var out: [Int: Date] = [:]
        for (key, record) in loadAll() {
            if let id = Int(key) { out[id] = record.updatedAt }
        }
        return out
    }

    static func save(bookId: Int, _ record: Record) {
        save(key: "\(bookId)", record)
    }

    /// Take the server's position for a book when it is clearly newer than
    /// this device's. The server keeps whatever was written last, from any
    /// device, so a device that resumed from its own stale copy and wrote it
    /// back moved every other device back with it. The margin tolerates clock
    /// skew and this device's own write racing the read. Returns the record
    /// the reader should restore from.
    @discardableResult
    static func reconcile(bookId: Int, with progress: ReadingProgress?) -> Record? {
        let local = get(bookId: bookId)
        guard let progress, progress.enabled != 0,
              let slug = progress.chapterSlug, let idx = progress.chapterIndex else { return local }
        let serverDate = parseServerDate(progress.updatedAt)
        let margin: TimeInterval = 90
        let serverNewer = local == nil
            || (serverDate.map { $0 > local!.updatedAt.addingTimeInterval(margin) } ?? false)
        guard serverNewer else { return local }
        let serverView = progress.view ?? "full"
        let serverPos = Int((progress.position ?? 0).rounded())
        // The server stores one position (the active view's); keep the other
        // view's local position when it belongs to the same chapter.
        let keepSame = local?.chapterSlug == slug
        let adopted = Record(
            chapterIndex: idx, chapterSlug: slug,
            lastView: serverView,
            fullChar: serverView == "full" ? serverPos : (keepSame ? (local?.fullChar ?? 0) : 0),
            summaryPara: serverView == "summary" ? serverPos : (keepSame ? (local?.summaryPara ?? 0) : 0),
            updatedAt: serverDate ?? .init())
        save(bookId: bookId, adopted)
        return adopted
    }

    /// SQLite's `datetime('now')` ("YYYY-MM-DD HH:MM:SS", UTC).
    private static func parseServerDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)
    }

    // Articles share the store under a prefixed string key ("article:fr/slug")
    // — same record shape, the article being its own single "chapter".
    static func get(key: String) -> Record? { loadAll()[key] }

    static func save(key: String, _ record: Record) {
        var all = loadAll()
        all[key] = record
        guard let url = fileURL() else { return }
        try? JSONEncoder().encode(all).write(to: url, options: .atomic)
    }

    /// Forget a book's position. The reset button has to clear this as well as
    /// the server's row: the local record is the one the detail view prefers,
    /// so leaving it behind would put the reader straight back where they were.
    static func clear(bookId: Int) {
        var all = loadAll()
        all.removeValue(forKey: "\(bookId)")
        guard let url = fileURL() else { return }
        try? JSONEncoder().encode(all).write(to: url, options: .atomic)
    }

    // MARK: - Paused books
    //
    // Tracking paused for a book means the reader stops recording: go and
    // consult the index or a chapter well ahead without it counting as read.
    // The server holds the truth (its `enabled` column), but the reader writes
    // locally first and offline, so it needs the answer on device too. Mirrored
    // here whenever the server's is read or the reader changes it.

    static func pausedURL() -> URL? { MemberStore.file("paused.json") }

    private static func loadPaused() -> Set<Int> {
        guard let url = pausedURL(), let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode(Set<Int>.self, from: data) else { return [] }
        return ids
    }

    static func isPaused(bookId: Int) -> Bool { loadPaused().contains(bookId) }

    static func setPaused(_ paused: Bool, bookId: Int) {
        var ids = loadPaused()
        if paused { ids.insert(bookId) } else { ids.remove(bookId) }
        guard let url = pausedURL() else { return }
        try? JSONEncoder().encode(ids).write(to: url, options: .atomic)
    }
}
