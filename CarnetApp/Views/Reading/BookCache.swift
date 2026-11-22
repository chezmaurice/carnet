import Foundation
import CryptoKit

/// On-device store for whole books downloaded for offline reading. Each cached
/// book keeps every chapter's full text (and summary, when it has one) plus a
/// manifest. Lives in Application Support (not Caches, so iOS won't purge a
/// user-requested download) and is excluded from iCloud backup. Keyed by a
/// stable hash of server + bookId so households don't collide.
enum BookCache {
    private static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("OfflineBooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var mutable = d
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? mutable.setResourceValues(rv)
        return d
    }()

    struct Manifest: Codable {
        let chapterSlugs: [String]
        let sizeBytes: Int
        let downloadedAt: String
        // Book + chapter metadata snapshotted at download time, so the shelf and
        // chapter list render offline. Optional for back-compat with old manifests.
        var book: Book?
        var chapters: [Chapter]?
    }

    // MARK: - Paths

    private static func bookDir(_ bookId: Int) -> URL {
        let h = hash("\(CarnetAPI.baseURL)#\(bookId)")
        return root.appendingPathComponent(h, isDirectory: true)
    }
    /// The last-seen library list, per server (household), for offline browsing.
    private static func libraryURL() -> URL {
        root.appendingPathComponent("library-\(hash(CarnetAPI.baseURL))").appendingPathExtension("json")
    }
    private static func manifestURL(_ bookId: Int) -> URL {
        bookDir(bookId).appendingPathComponent("manifest.json")
    }
    private static func fullURL(_ bookId: Int, _ slug: String) -> URL {
        bookDir(bookId).appendingPathComponent(hash(slug)).appendingPathExtension("full")
    }
    private static func summaryURL(_ bookId: Int, _ slug: String) -> URL {
        bookDir(bookId).appendingPathComponent(hash(slug)).appendingPathExtension("sum")
    }
    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Query

    /// True once the user has downloaded the whole book (the "download all
    /// chapters" toggle). This is what "available offline" means.
    static func isDownloaded(bookId: Int) -> Bool {
        FileManager.default.fileExists(atPath: manifestURL(bookId).path)
    }
    static func manifest(bookId: Int) -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL(bookId)) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }
    static func size(bookId: Int) -> Int { manifest(bookId: bookId)?.sizeBytes ?? 0 }

    /// Chapter list captured at download time — lets a downloaded book render offline.
    static func cachedChapters(bookId: Int) -> [Chapter]? { manifest(bookId: bookId)?.chapters }

    // MARK: - Library list (offline browsing)

    static func cacheBooksList(_ books: [Book]) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(books).write(to: libraryURL(), options: .atomic)
    }
    static func cachedBooksList() -> [Book]? {
        guard let data = try? Data(contentsOf: libraryURL()) else { return nil }
        return try? JSONDecoder().decode([Book].self, from: data)
    }

    static func chapterText(bookId: Int, slug: String) -> String? {
        try? String(contentsOf: fullURL(bookId, slug), encoding: .utf8)
    }
    static func chapterSummary(bookId: Int, slug: String) -> String? {
        try? String(contentsOf: summaryURL(bookId, slug), encoding: .utf8)
    }

    static func hasChapterText(bookId: Int, slug: String) -> Bool {
        FileManager.default.fileExists(atPath: fullURL(bookId, slug).path)
    }
    static func hasChapterSummary(bookId: Int, slug: String) -> Bool {
        FileManager.default.fileExists(atPath: summaryURL(bookId, slug).path)
    }
    /// True if any of this chapter's content (full text or summary) is on device.
    static func isChapterCached(bookId: Int, slug: String) -> Bool {
        hasChapterText(bookId: bookId, slug: slug) || hasChapterSummary(bookId: bookId, slug: slug)
    }

    // MARK: - Per-chapter cache (fills in as you read, independent of a full download)

    static func cacheChapterText(bookId: Int, slug: String, text: String) {
        write(text, to: fullURL(bookId, slug), bookId: bookId)
    }
    static func cacheChapterSummary(bookId: Int, slug: String, text: String) {
        write(text, to: summaryURL(bookId, slug), bookId: bookId)
    }
    private static func write(_ text: String, to url: URL, bookId: Int) {
        try? FileManager.default.createDirectory(at: bookDir(bookId), withIntermediateDirectories: true)
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: - Mutate

    static func remove(bookId: Int) {
        try? FileManager.default.removeItem(at: bookDir(bookId))
    }

    /// Download every chapter's full text (+ summary when present), reporting
    /// progress as (completed, total) on the main actor. Writes the manifest only
    /// once all chapters succeed; a thrown/cancelled download leaves no manifest.
    static func download(book: Book, chapters: [Chapter],
                         onProgress: @escaping (Int, Int) -> Void) async throws {
        let bookId = book.id
        let dir = bookDir(bookId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let total = chapters.count
        var done = 0
        var sizeBytes = 0

        try await withThrowingTaskGroup(of: Int.self) { group in
            var it = chapters.makeIterator()
            let maxConcurrent = 6

            func addNext() {
                guard let ch = it.next() else { return }
                group.addTask {
                    try Task.checkCancellation()
                    var written = 0
                    // Retry once — a single flaky/slow chapter over a remote tunnel
                    // shouldn't abort the whole download.
                    let text: String
                    do {
                        text = try await CalibreAPI.chapter(bookId: bookId, slug: ch.slug).text
                    } catch {
                        if error.isCancellation { throw error }
                        text = try await CalibreAPI.chapter(bookId: bookId, slug: ch.slug).text
                    }
                    try text.data(using: .utf8)?.write(to: fullURL(bookId, ch.slug), options: .atomic)
                    written += text.utf8.count
                    if ch.hasSummary,
                       let summary = try? await CalibreAPI.chapterSummary(bookId: bookId, slug: ch.slug).summary {
                        try? summary.data(using: .utf8)?.write(to: summaryURL(bookId, ch.slug), options: .atomic)
                        written += summary.utf8.count
                    }
                    return written
                }
            }

            for _ in 0..<maxConcurrent { addNext() }
            while let written = try await group.next() {
                done += 1
                sizeBytes += written
                let d = done
                await MainActor.run { onProgress(d, total) }
                addNext()
            }
        }

        try Task.checkCancellation()
        let manifest = Manifest(chapterSlugs: chapters.map(\.slug), sizeBytes: sizeBytes,
                                downloadedAt: ISO8601DateFormatter().string(from: .now),
                                book: book, chapters: chapters)
        try JSONEncoder().encode(manifest).write(to: manifestURL(bookId), options: .atomic)
    }

    /// Human-readable size for the offline row.
    static func formatSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
