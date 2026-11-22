import Foundation

// MARK: - Queue Models

enum QueueItemType: String, Codable {
    case articleScrape
    case fileUpload
    case bankTransaction
    /// An EPUB or a PDF for the household's library (`POST /api/v1/calibre/add`).
    case libraryBook
}

struct QueuePayload: Codable {
    var url: String?
    var tags: [String]?
    var filename: String?
    var mimeType: String?
    /// The note written at the moment of saving — the reason this was kept.
    /// Optional, so manifests queued by an earlier build still decode.
    var comment: String?
    /// Which surface captured it (ios-share, …), for later triage on the server.
    var sourceClient: String?
    var title: String?
    var selection: String?
    /// The rendered DOM is megabytes; it rides in the queue's file store rather
    /// than the manifest, so listing the queue does not read it back.
    var hasHtml: Bool?
}

struct QueueItem: Codable, Identifiable {
    let id: UUID
    let type: QueueItemType
    let createdAt: Date
    let payload: QueuePayload
    /// Who made the capture, where: it is sent there and as them, whoever is
    /// signed in when the queue is flushed. Stamped by `enqueue`; absent from
    /// items queued by a build before 21 October 2026.
    var origin: QueueOrigin? = nil
}

/// The household and member a capture belongs to.
struct QueueOrigin: Codable, Hashable {
    /// The device-local household id (the Keychain's token key carries it).
    let householdId: String
    let memberId: String
    let serverURL: String

    /// Whoever is active now, as the App Group mirror says.
    static var current: QueueOrigin? {
        let d = CarnetAPI.defaults
        guard let hid = d.string(forKey: "carnet.currentHouseholdId"),
              let mid = d.string(forKey: "carnet.activeMemberId"),
              !CarnetAPI.baseURL.isEmpty else { return nil }
        return QueueOrigin(householdId: hid, memberId: mid, serverURL: CarnetAPI.baseURL)
    }

    /// The member's session on this device, if they still have one.
    var token: String? { TokenVault.get("carnet.token.\(householdId).\(memberId)") }
}

// MARK: - OfflineQueue

final class OfflineQueue {
    static let shared = OfflineQueue()

    private let queueDir: URL
    private let filesDir: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: CarnetAPI.appGroupID
        ) ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        queueDir = container.appendingPathComponent("queue", isDirectory: true)
        filesDir = queueDir.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func enqueue(_ item: QueueItem, fileData: Data? = nil) {
        var item = item
        if item.origin == nil { item.origin = .current }
        let manifestURL = queueDir.appendingPathComponent("\(item.id.uuidString).json")
        if let data = try? encoder.encode(item) {
            try? data.write(to: manifestURL)
        }
        if let fileData {
            let fileURL = filesDir.appendingPathComponent("\(item.id.uuidString).dat")
            try? fileData.write(to: fileURL)
        }
    }

    func pendingItems() -> [QueueItem] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: queueDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> QueueItem? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(QueueItem.self, from: data)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func pendingCount() -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: queueDir, includingPropertiesForKeys: nil) else {
            return 0
        }
        return files.filter { $0.pathExtension == "json" }.count
    }

    func fileData(for id: UUID) -> Data? {
        let fileURL = filesDir.appendingPathComponent("\(id.uuidString).dat")
        return try? Data(contentsOf: fileURL)
    }

    func dequeue(_ id: UUID) {
        let manifestURL = queueDir.appendingPathComponent("\(id.uuidString).json")
        let fileURL = filesDir.appendingPathComponent("\(id.uuidString).dat")
        try? FileManager.default.removeItem(at: manifestURL)
        try? FileManager.default.removeItem(at: fileURL)
    }
}
