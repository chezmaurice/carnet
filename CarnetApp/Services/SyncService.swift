import Foundation
import Network
import Observation

@Observable
final class SyncService {
    var pendingCount: Int = 0
    var isSyncing: Bool = false
    var lastSyncDate: Date?
    var lastError: String?
    /// Captures kept because the member who made them has no session on this
    /// device any more (signed out, removed, refused): sent once they sign in
    /// again. Counted per member.
    var stranded: [QueueOrigin: Int] = [:]

    private let queue = OfflineQueue.shared
    private var monitor: NWPathMonitor?

    init() {
        refreshCount()
    }

    func startMonitoring() {
        monitor?.cancel()
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { await self?.syncNow() }
        }
        monitor.start(queue: DispatchQueue(label: "eu.chezmaurice.carnet.app.sync-monitor"))
    }

    func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
    }

    func refreshCount() {
        pendingCount = queue.pendingCount()
    }

    @MainActor
    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastError = nil
        defer {
            isSyncing = false
            refreshCount()
        }

        let items = queue.pendingItems()
        var waiting: [QueueOrigin: Int] = [:]
        for item in items {
            do {
                if let origin = item.origin {
                    // Sent to the household and as the member it was made by.
                    guard let token = origin.token else {
                        waiting[origin, default: 0] += 1
                        continue
                    }
                    try await CarnetAPI.$identity.withValue(.init(serverURL: origin.serverURL, token: token)) {
                        try await flush(item)
                    }
                } else {
                    try await flush(item)
                }
                queue.dequeue(item.id)
            } catch {
                lastError = "\(item.payload.filename ?? item.payload.url ?? item.id.uuidString): \(error.localizedDescription)"
            }
        }
        stranded = waiting
        lastSyncDate = Date()
    }

    private func flush(_ item: QueueItem) async throws {
        switch item.type {
        case .articleScrape:
            guard let url = item.payload.url else { return }
            let html = item.payload.hasHtml == true
                ? queue.fileData(for: item.id).flatMap { String(data: $0, encoding: .utf8) }
                : nil
            _ = try await CarnetAPI.saveArticle(
                url: url,
                comment: item.payload.comment,
                tags: item.payload.tags,
                sourceClient: item.payload.sourceClient ?? "ios-share",
                html: html,
                title: item.payload.title,
                selection: item.payload.selection
            )

        case .fileUpload:
            guard let filename = item.payload.filename,
                  let data = queue.fileData(for: item.id) else { return }
            let mime = item.payload.mimeType ?? "application/octet-stream"
            _ = try await CarnetAPI.upload(data: data, filename: filename, mimeType: mime)

        case .libraryBook:
            guard let filename = item.payload.filename,
                  let data = queue.fileData(for: item.id) else { return }
            do {
                _ = try await CarnetAPI.addBookToCalibre(data: data, filename: filename)
            } catch CarnetAPI.APIError.serverError(let message) {
                // The server read it and said no (not a book, no library on
                // this household): sending it again would say the same.
                lastError = "\(filename): \(message)"
            }

        case .bankTransaction:
            guard let filename = item.payload.filename,
                  let data = queue.fileData(for: item.id) else { return }
            _ = try await CarnetAPI.uploadBankTransaction(
                data: data, filename: filename, timestamp: item.createdAt
            )
        }
    }
}
