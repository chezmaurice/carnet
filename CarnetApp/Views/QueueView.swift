import SwiftUI

struct QueueView: View {
    @Environment(SyncService.self) private var syncService
    @State private var items: [QueueItem] = []

    var body: some View {
        @Bindable var sync = syncService

        NavigationStack {
            List {
                Section {
                    HStack {
                        Circle()
                            .fill(syncService.isSyncing ? .orange : .green)
                            .frame(width: 8, height: 8)
                        Text(syncService.isSyncing ? "Syncing..." : "Ready")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let date = syncService.lastSyncDate {
                            Text(date, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task {
                            await syncService.syncNow()
                            reload()
                        }
                    } label: {
                        HStack {
                            Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if syncService.isSyncing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(syncService.isSyncing || items.isEmpty)
                }

                if let error = syncService.lastError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                if items.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Queue Empty",
                            systemImage: "checkmark.circle",
                            description: Text("All items have been synced.")
                        )
                    }
                } else {
                    Section("Pending (\(items.count))") {
                        ForEach(items) { item in
                            HStack {
                                Image(systemName: iconName(for: item.type))
                                    .foregroundStyle(iconColor(for: item.type))
                                VStack(alignment: .leading) {
                                    Text(displayName(for: item))
                                        .font(.body)
                                    Text(item.createdAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                OfflineQueue.shared.dequeue(items[index].id)
                            }
                            reload()
                        }
                    }
                }
            }
            .navigationTitle("Queue")
            .onAppear { reload() }
        }
    }

    private func reload() {
        items = OfflineQueue.shared.pendingItems()
        syncService.refreshCount()
    }

    private func iconName(for type: QueueItemType) -> String {
        switch type {
        case .articleScrape: return "doc.text"
        case .libraryBook: return "book"
        }
    }

    private func iconColor(for type: QueueItemType) -> Color {
        switch type {
        case .articleScrape: return .blue
        case .libraryBook: return .blue
        }
    }

    private func displayName(for item: QueueItem) -> String {
        item.payload.filename ?? item.payload.url ?? item.id.uuidString
    }
}
