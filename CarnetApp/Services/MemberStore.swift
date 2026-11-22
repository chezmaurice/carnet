import Foundation
import CryptoKit

/// Where a member's own data is kept on this device: the last-seen shelf, the
/// saved articles and their captured text, the garden entries, the reading
/// positions. One folder per member of each household —
/// `Application Support/Members/<sha256(server#member)>/` — so a phone shared
/// by several members never shows one member what another saved, and signing
/// a member out removes everything kept for them in one go.
///
/// What the household shares stays keyed by server alone: the Calibre library
/// and downloaded books (BookCache), the covers (CoverCache).
enum MemberStore {
    private static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Members", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var mutable = d
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? mutable.setResourceValues(rv)
        return d
    }()

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func folder(server: String, member: String) -> URL {
        root.appendingPathComponent(hash("\(server)#\(member)"), isDirectory: true)
    }

    /// The signed-in member's folder, created on demand. Nil when no member
    /// is signed in: then nothing is read or written.
    static var current: URL? {
        let server = CarnetAPI.baseURL
        guard !server.isEmpty, let member = CarnetAPI.activeMemberId, !member.isEmpty else { return nil }
        let d = folder(server: server, member: member)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A file in the signed-in member's folder.
    static func file(_ name: String) -> URL? {
        current?.appendingPathComponent(name)
    }

    /// Forget everything kept for a member: signed out, session refused,
    /// household unpaired.
    static func purge(server: String, member: String) {
        try? FileManager.default.removeItem(at: folder(server: server, member: member))
    }

    // MARK: - Before members had folders

    /// Up to 1.0.1 these caches were keyed by server only, so whoever signed
    /// in next was shown them. The lists and texts are fetched again; the
    /// reading positions (which the server also keeps) go to the member
    /// active at upgrade — on a phone shared by several, usually its owner.
    static func migrateLegacy() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let articles = base.appendingPathComponent("OfflineArticles", isDirectory: true)
        let positions = base.appendingPathComponent("ReadingPositions", isDirectory: true)

        if fm.fileExists(atPath: positions.path) {
            let h = hash(CarnetAPI.baseURL)
            let moves: [(String, URL?)] = [
                ("positions-\(h).json", ReadingPositionStore.fileURL()),
                ("paused-\(h).json", ReadingPositionStore.pausedURL()),
            ]
            for (name, target) in moves {
                let legacy = positions.appendingPathComponent(name)
                guard fm.fileExists(atPath: legacy.path), let target,
                      !fm.fileExists(atPath: target.path) else { continue }
                try? fm.moveItem(at: legacy, to: target)
            }
            try? fm.removeItem(at: positions)
        }
        if fm.fileExists(atPath: articles.path) { try? fm.removeItem(at: articles) }
    }
}
