import SwiftUI
import CryptoKit

/// How the garden is ordered. Last written on is the default: the garden is a
/// working surface, and what you wrote on last is what you come back to. The
/// subject's own date is the other useful axis — when a book came out, when a
/// film was watched — and it is what the server sorts on.
enum GardenSort: String, GridSortChoice {
    case edited, date, title
    static var defaultChoice: GardenSort { .edited }
    var label: String {
        switch self {
        case .edited: return "Last written on"
        case .date: return "Entry date"
        case .title: return "Title"
        }
    }
}

/// Garden home — every entry of the member's garden, all collections, with a
/// filter per content type. Contents aren't read in the app (articles have the
/// Reading shelf for that; the rest belongs to the browser and the editors) —
/// each entry opens its card or fiche where it lives.
///
/// Unopened fiches (article shares nobody has written on) stay out: they are
/// the Reading shelf's business until a note makes them a fiche.
struct GardenView: View {
    /// Opens the app drawer (shown as ☰ in the header when hosted in the shell).
    var onMenu: (() -> Void)? = nil

    @State private var entries: [GardenEntry] = []
    @State private var username = ""
    @State private var loading = true
    @State private var error: String?
    @State private var filter: String = ""   // collection raw value; "" = all
    @State private var searching = false
    @State private var query = ""
    @State private var didStartLoad = false
    @State private var offlineCache = false
    @AppStorage("carnet.garden.sort") private var sortRaw = GardenSort.defaultChoice.rawValue
    private var sort: GardenSort { GardenSort(rawValue: sortRaw) ?? .defaultChoice }

    private func iconChrome(_ systemName: String, on: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(on ? CarnetTheme.accentInk : CarnetTheme.ink)
            .frame(width: 32, height: 32)
            .background(on ? CarnetTheme.accent : Color.clear)
            .overlay(Rectangle().strokeBorder(on ? CarnetTheme.accent : CarnetTheme.ruleHard, lineWidth: 1))
    }

    /// Collections that actually hold entries, in GardenCollection order —
    /// the filter menu only offers what exists.
    private var presentCollections: [GardenCollection] {
        let present = Set(openedEntries.map(\.collection))
        return GardenCollection.allCases.filter { present.contains($0.rawValue) }
    }

    private var openedEntries: [GardenEntry] { entries.filter(\.isOpened) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GridHeader(title: "Notes",
                           kicker: loading ? nil : (offlineCache ? "Offline · \(visibleEntries.count)" : "\(visibleEntries.count)"),
                           menu: onMenu) {
                    HStack(spacing: 7) {
                        Menu {
                            Picker("Type", selection: $filter) {
                                Text("All").tag("")
                                ForEach(presentCollections) { c in
                                    Label(c.label, systemImage: c.symbol).tag(c.rawValue)
                                }
                            }
                        } label: {
                            iconChrome("line.3.horizontal.decrease", on: !filter.isEmpty)
                        }
                        GridSortMenu<GardenSort>(raw: $sortRaw)
                        GridIconButton(systemName: "magnifyingglass", size: 32) {
                            withAnimation(.easeOut(duration: 0.15)) { searching.toggle() }
                        }
                    }
                }
                if loading {
                    GridLoading()
                } else if let error {
                    GridMessage(text: error)
                } else {
                    content
                }
            }
            .background(CarnetTheme.bg)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: GardenEntry.self) {
                GardenEntryView(entry: $0, username: username)
            }
            .onAppear {
                guard !didStartLoad else { return }
                didStartLoad = true
                load()
            }
            .refreshable { await fetch() }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                if searching {
                    TextField("Search title", text: $query)
                        .font(CarnetTheme.mono(13))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(CarnetTheme.surface)
                        .overlay(Rectangle().strokeBorder(CarnetTheme.ruleHard, lineWidth: 1))
                        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                        .padding(.bottom, 12)
                }

                if let active = GardenCollection(rawValue: filter) {
                    HStack(spacing: 8) {
                        GridLabel(active.label, size: 9.5, color: CarnetTheme.inkSoft)
                        Spacer(minLength: 0)
                        Button { filter = "" } label: {
                            GridLabel("Clear", size: 9.5, color: CarnetTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                }

                GridRule()

                if visibleEntries.isEmpty {
                    Text("Nothing here")
                        .font(CarnetTheme.caption)
                        .foregroundStyle(CarnetTheme.inkHint)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleEntries) { entry in
                            NavigationLink(value: entry) {
                                GardenEntryRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            GridRule()
                        }
                    }
                }
            }
        }
    }

    private var visibleEntries: [GardenEntry] {
        openedEntries.filter { filter.isEmpty || $0.collection == filter }
            .filter { e in
                guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
                return e.title.lowercased().contains(query.lowercased())
            }
            .sorted(by: entryOrder)
    }

    private func entryOrder(_ a: GardenEntry, _ b: GardenEntry) -> Bool {
        switch sort {
        case .edited:
            switch (a.updatedDate, b.updatedDate) {
            case let (x?, y?): return x == y ? byTitle(a, b) : x > y
            case (_?, nil): return true
            case (nil, _?): return false
            // No mtime on either side — an older server, or a cached list.
            // Falling back on the entry date keeps the list in the server's
            // own order rather than scrambling it to alphabetical.
            case (nil, nil): return a.date == b.date ? byTitle(a, b) : a.date > b.date
            }
        case .date: return a.date == b.date ? byTitle(a, b) : a.date > b.date
        case .title: return byTitle(a, b)
        }
    }

    private func byTitle(_ a: GardenEntry, _ b: GardenEntry) -> Bool {
        let c = a.title.localizedCaseInsensitiveCompare(b.title)
        return c == .orderedSame ? a.id < b.id : c == .orderedAscending
    }

    // MARK: - Loading (cache-first, like the shelves)

    private func load() {
        if entries.isEmpty, let cached = GardenEntriesCache.cached() {
            entries = cached.entries
            username = cached.garden.username
            offlineCache = true
            loading = false
        }
        Task { await fetch() }
    }

    private func fetch() async {
        do {
            let response = try await GardenAPI.entries()
            entries = response.entries
            username = response.garden.username
            GardenEntriesCache.cache(response)
            offlineCache = false
            error = nil
            loading = false
        } catch {
            if error.isCancellation {
                if entries.isEmpty { didStartLoad = false }
                loading = false
                return
            }
            if let cached = GardenEntriesCache.cached() {
                entries = cached.entries
                username = cached.garden.username
                offlineCache = true
                self.error = nil
            } else if entries.isEmpty {
                self.error = "Couldn't load your notes.\n\(error.localizedDescription)"
            }
            loading = false
        }
    }
}

// MARK: - Row

private struct GardenEntryRow: View {
    let entry: GardenEntry

    private var collection: GardenCollection? { GardenCollection(rawValue: entry.collection) }

    var body: some View {
        HStack(spacing: 14) {
            CoverImage(entry: entry)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.title)
                    .font(CarnetTheme.sans(15.5, weight: .semibold))
                    .tracking(-0.15)
                    .foregroundStyle(CarnetTheme.ink)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let collection {
                        Image(systemName: collection.symbol).font(.system(size: 10))
                        Text(collection.label)
                    } else {
                        Text(entry.collection)
                    }
                    if !entry.date.isEmpty { Text("· \(entry.date)") }
                }
                .font(CarnetTheme.sans(12.5))
                .foregroundStyle(CarnetTheme.inkMute)
                .padding(.top, 2)

                HStack(spacing: 14) {
                    if entry.card != nil { GridLabel("Card", size: 9.5) }
                    if entry.fiche != nil { GridLabel("Fiche", size: 9.5, color: CarnetTheme.inkSoft) }
                }
                .padding(.top, 9)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.vertical, 15)
        .contentShape(Rectangle())
    }
}

// MARK: - Cache (offline browsing)

/// Last-seen entries list, in the signed-in member's folder (MemberStore).
enum GardenEntriesCache {
    private static var url: URL? { MemberStore.file("garden-entries.json") }

    static func cache(_ response: GardenEntriesResponse) {
        guard let url else { return }
        try? JSONEncoder().encode(response).write(to: url, options: .atomic)
    }
    static func cached() -> GardenEntriesResponse? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GardenEntriesResponse.self, from: data)
    }
}
