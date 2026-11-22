import SwiftUI

// MARK: - Shelves (Books · Articles)

/// The Reading section holds two shelves: the Calibre library and the garden's
/// saved articles. One enum + toggle, hosted by LibraryView.
enum ReadingShelf: String, CaseIterable, Identifiable {
    case books, articles, domains
    var id: String { rawValue }
    var label: String {
        switch self {
        case .books: return "Books"
        case .articles: return "Articles"
        // What Maurice keeps on the member — briefs are read and corrected
        // here, which makes them a shelf of the reading section.
        case .domains: return "Domains"
        }
    }
}

/// The leading chrome of both shelves: the member badge in the minimal scope
/// (opens the member/household sheet), ☰ when hosted in the drawer shell.
struct ShelfIdentity: View {
    var menu: (() -> Void)? = nil
    var identity: (() -> Void)? = nil
    @Environment(CarnetSession.self) private var session

    var body: some View {
        if let identity {
            Button(action: identity) {
                MemberBadge(member: session.activeMember, size: 28)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Member and household")
        }
        if let menu {
            Button(action: menu) {
                GridIconGlyph(systemName: "line.3.horizontal", size: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Menu")
        }
    }
}

/// BOOKS | ARTICLES segmented toggle, rendered under the header on both shelves.
struct ShelfToggle: View {
    @Binding var shelf: ReadingShelf

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ReadingShelf.allCases) { s in
                let on = shelf == s
                Button { shelf = s } label: {
                    Text(s.label.uppercased())
                        .font(CarnetTheme.mono(10.5))
                        .tracking(0.6)
                        .foregroundStyle(on ? CarnetTheme.bg : CarnetTheme.inkMute)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(on ? CarnetTheme.ink : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(Rectangle().strokeBorder(CarnetTheme.ruleHard, lineWidth: 1))
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.bottom, 12)
    }
}

/// How the shelf is ordered. Reading order is the default: the library is a
/// place you come back to, so what you last had open, then what most recently
/// arrived. The rest are for finding one specific book.
enum LibrarySort: String, GridSortChoice {
    case reading, added, title, author
    static var defaultChoice: LibrarySort { .reading }
    var label: String {
        switch self {
        case .reading: return "Last opened"
        case .added: return "Recently added"
        case .title: return "Title"
        case .author: return "Author"
        }
    }
}

/// Reading home — the Calibre library. Grid theme; port of the design's TLibrary.
/// Owns the reading `NavigationStack`; rows push the book detail.
struct LibraryView: View {
    /// Injected sample data for previews/verification; nil = load from the server.
    var previewBooks: [Book]? = nil
    /// Opens the app drawer (shown as ☰ in the header when hosted in the shell).
    var onMenu: (() -> Void)? = nil
    /// Opens the member/household sheet (member badge in the header, minimal scope).
    var onIdentity: (() -> Void)? = nil

    @State private var books: [Book] = []
    @State private var loading = true
    @State private var error: String?
    @State private var filter: LibraryFilter = .all
    @State private var downloadedOnly = false
    @State private var searching = false
    @State private var query = ""
    @State private var didStartLoad = false
    /// True when the list is served from the on-device cache (server unreachable).
    @State private var offlineCache = false
    /// Downloaded book ids — observable so markers/filter refresh after a download.
    @State private var downloadedIds: Set<Int> = []
    @AppStorage("carnet.library.sort") private var sortRaw = LibrarySort.defaultChoice.rawValue
    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .defaultChoice }
    /// Book id → last time the reader left off in it, for the shelf order.
    /// Re-read on appear, so coming back from the reader floats that book up.
    @State private var lastOpened: [Int: Date] = [:]
    /// The reading stack. Owned here so a notification tap (the router) and
    /// the Domains shelf (a companion's book) can push onto it.
    @State private var path = NavigationPath()
    @Environment(CarnetRouter.self) private var router
    /// Which shelf is showing. Remembered across launches — a reader who lives
    /// in articles shouldn't land on books every time.
    @AppStorage("carnet.reading.shelf") private var shelfRaw = ReadingShelf.books.rawValue
    private var shelf: Binding<ReadingShelf> {
        Binding(get: { ReadingShelf(rawValue: shelfRaw) ?? .books },
                set: { shelfRaw = $0.rawValue })
    }

    private func refreshDownloaded() {
        downloadedIds = Set(books.filter { BookCache.isDownloaded(bookId: $0.id) }.map(\.id))
    }

    private func refreshLastOpened() {
        lastOpened = ReadingPositionStore.lastOpenedByBook()
    }

    private var activeFilterSummary: String {
        var parts: [String] = []
        if filter != .all { parts.append(filter.label) }
        if downloadedOnly { parts.append("Downloaded") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch shelf.wrappedValue {
                case .articles:
                    ArticlesShelfView(onMenu: onMenu, onIdentity: onIdentity, shelf: shelf)
                case .domains:
                    DomainsShelfView(onMenu: onMenu, onIdentity: onIdentity, shelf: shelf,
                                     openBook: { path.append($0) })
                case .books:
                    booksShelf
                }
            }
            .background(CarnetTheme.bg)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Book.self) { BookDetailView(book: $0, libraryOffline: offlineCache) }
            .navigationDestination(for: Article.self) { ArticleDetailView(article: $0) }
            .navigationDestination(for: DomainSummary.self) { DomainBriefView(domain: $0) }
            .navigationDestination(for: OpenedConversationRoute.self) { OpenedConversationView(conversationId: $0.id) }
        }
        .task { openPendingConversation() }
        .onChange(of: router.openConversationId) { _, _ in openPendingConversation() }
    }

    /// A notification tap lands here: the conversation Maurice opened is
    /// pushed on top of whatever was showing, from the Domains shelf.
    private func openPendingConversation() {
        guard let id = router.openConversationId else { return }
        router.openConversationId = nil
        shelf.wrappedValue = .domains
        path = NavigationPath()
        path.append(OpenedConversationRoute(id: id))
    }

    private var booksShelf: some View {
        // The chrome floats: the identity badge (or ☰) alone on the left, the
        // actions together on the right, search in the bottom bar — and the
        // title, the shelf toggle and the list scroll beneath them.
        ScrollView {
            VStack(spacing: 0) {
                GridTitle(title: "Library",
                          kicker: loading ? "Calibre" : (offlineCache ? "Offline · \(books.count)" : "Calibre · \(books.count)"))
                ShelfToggle(shelf: shelf)
                if loading {
                    GridLoading().frame(minHeight: 240)
                } else if let error {
                    GridMessage(text: error)
                } else {
                    content
                }
            }
        }
        .refreshable { await fetch() }
        .gridTopChrome {
            GridChromeRow {
                ShelfIdentity(menu: onMenu, identity: onIdentity)
            } trailing: {
                // Filters live behind an icon menu instead of a text-chip row.
                Menu {
                    Picker("Filter", selection: $filter) {
                        ForEach(LibraryFilter.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    GridIconGlyph(systemName: "line.3.horizontal.decrease", on: filter != .all, size: 32)
                }
                .accessibilityLabel("Filter")
                // Downloaded-only toggle.
                GridIconButton(systemName: "arrow.down.circle", primary: downloadedOnly, size: 32) {
                    downloadedOnly.toggle()
                }
                .accessibilityLabel("Downloaded only")
                GridSortMenu<LibrarySort>(raw: $sortRaw)
            }
        }
        .gridBottomChrome {
            GridSearchBar(searching: $searching, query: $query, placeholder: "Search title or author")
        }
        .onAppear {
            refreshDownloaded()   // reflects downloads made in the detail view
            refreshLastOpened()   // and reading done since we were last on screen
            guard !didStartLoad else { return }
            didStartLoad = true
            load()
        }
    }

    private var content: some View {
        Group {
            VStack(spacing: 0) {
                // Active-filter breadcrumb (only when a filter/toggle narrows the list).
                if filter != .all || downloadedOnly {
                    HStack(spacing: 8) {
                        GridLabel(activeFilterSummary, size: 9.5, color: CarnetTheme.inkSoft)
                        Spacer(minLength: 0)
                        Button { filter = .all; downloadedOnly = false } label: {
                            GridLabel("Clear", size: 9.5, color: CarnetTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                }

                GridRule()

                if visibleBooks.isEmpty {
                    Text("No books")
                        .font(CarnetTheme.caption)
                        .foregroundStyle(CarnetTheme.inkHint)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                } else {
                    // Lazy: a library runs to a few hundred books, and an eager
                    // stack built every row at once — with it, every row's
                    // cover fetch started at once and most of them queued
                    // behind a connection rather than a server.
                    LazyVStack(spacing: 0) {
                        ForEach(visibleBooks) { book in
                            NavigationLink(value: book) {
                                BookRow(book: book, downloaded: downloadedIds.contains(book.id), offline: offlineCache)
                            }
                            .buttonStyle(.plain)
                            GridRule()
                        }
                    }
                }
            }
        }
    }

    private var visibleBooks: [Book] {
        books.filter { filter.matches($0) }
            .filter { !downloadedOnly || downloadedIds.contains($0.id) }
            .filter { book in
                guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
                let q = query.lowercased()
                return book.title.lowercased().contains(q) || book.author.lowercased().contains(q)
            }
            .sorted(by: shelfOrder)
    }

    private func shelfOrder(_ a: Book, _ b: Book) -> Bool {
        switch sort {
        case .reading: return readingOrder(a, b)
        case .added: return newer(a.addedDate, b.addedDate) ?? byTitle(a, b)
        case .title: return byTitle(a, b)
        case .author:
            let c = a.author.localizedCaseInsensitiveCompare(b.author)
            return c == .orderedSame ? byTitle(a, b) : c == .orderedAscending
        }
    }

    /// The default: what you last opened, most recent first; then what you
    /// never opened, newest in the library first. A book with neither date
    /// (an offline list from a build that predates `added`) sorts by title.
    private func readingOrder(_ a: Book, _ b: Book) -> Bool {
        if let byOpening = newer(lastOpened[a.id], lastOpened[b.id]) { return byOpening }
        return newer(a.addedDate, b.addedDate) ?? byTitle(a, b)
    }

    /// Newest first, a date beating no date. Nil when the two can't be told
    /// apart, so the caller falls through to its own tie-break.
    private func newer(_ a: Date?, _ b: Date?) -> Bool? {
        switch (a, b) {
        case let (x?, y?): return x == y ? nil : x > y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return nil
        }
    }

    private func byTitle(_ a: Book, _ b: Book) -> Bool {
        let c = a.title.localizedCaseInsensitiveCompare(b.title)
        return c == .orderedSame ? a.id < b.id : c == .orderedAscending
    }

    /// Kick off the initial load in a detached-from-view Task, so SwiftUI
    /// cancelling `.task` on view churn (which was leaving the library spinning
    /// forever) can't cancel the fetch.
    private func load() {
        if let previewBooks { books = previewBooks; loading = false; return }
        // Cache-first: show the last-seen list immediately so the UI never blocks
        // on the network (offline, the fetch can hang or be cancelled). The
        // background fetch below replaces it when the server is reachable.
        if books.isEmpty, let cached = BookCache.cachedBooksList(), !cached.isEmpty {
            books = cached
            offlineCache = true   // provisional — cleared once a live fetch succeeds
            loading = false
            refreshDownloaded()
        }
        Task { await fetch() }
    }

    private func fetch() async {
        do {
            let fetched = try await CalibreAPI.books()
            books = fetched
            BookCache.cacheBooksList(fetched)   // keep a copy for offline browsing
            offlineCache = false
            error = nil
            loading = false
            refreshDownloaded()
        } catch {
            // A cancelled fetch just means view churn. If we already have content
            // shown (live or cached) there's nothing to do; only retry if we're
            // still blank.
            if error.isCancellation {
                if books.isEmpty { didStartLoad = false }
                loading = false
                return
            }
            // Server unreachable — fall back to the last-seen list so downloaded
            // books stay reachable offline.
            if let cached = BookCache.cachedBooksList(), !cached.isEmpty {
                books = cached
                offlineCache = true
                self.error = nil
            } else if books.isEmpty {
                self.error = "Couldn't load your library.\n\(error.localizedDescription)"
            }
            loading = false
        }
    }
}

// MARK: - Filter

/// Filters over the library's summarization state — the axis the list endpoint
/// exposes. (Per-member reading position isn't in the bulk payload, so
/// reading-based filters would need a batch endpoint; tracked as future work.)
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, unsummarized, partial, summarized
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .unsummarized: return "Unsummarized"
        case .partial: return "In progress"
        case .summarized: return "Summarized"
        }
    }

    func matches(_ b: Book) -> Bool {
        switch self {
        case .all: return true
        case .unsummarized: return b.hasChapters && b.summarizedCount == 0
        case .partial: return b.hasChapters && b.summarizedCount > 0 && !b.isFullySummarized
        case .summarized: return b.isFullySummarized
        }
    }
}

// MARK: - Row

private struct BookRow: View {
    let book: Book
    var downloaded: Bool = false
    var offline: Bool = false

    /// Offline, a book that wasn't downloaded can't be read — dim it and say so.
    private var unavailable: Bool { offline && !downloaded }

    var body: some View {
        HStack(spacing: 14) {
            CoverImage(bookId: book.id, letter: book.coverLetter)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(book.title)
                        .font(CarnetTheme.sans(15.5, weight: .semibold))
                        .tracking(-0.15)
                        .foregroundStyle(CarnetTheme.ink)
                        .lineLimit(2)
                    if downloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(CarnetTheme.inkMute)
                    }
                }
                Text(book.author)
                    .font(CarnetTheme.sans(12.5))
                    .foregroundStyle(CarnetTheme.inkMute)
                    .padding(.top, 2)
                    .lineLimit(1)

                if unavailable {
                    GridLabel("Unavailable offline", size: 9.5, color: CarnetTheme.inkMute)
                        .padding(.top, 9)
                } else if book.hasChapters {
                    HStack(spacing: 14) {
                        GridLabel("\(book.chapterCount) ch", size: 9.5)
                        GridLabel("\(book.summarizedCount)/\(book.chapterCount) summ", size: 9.5,
                                  color: book.summarizedCount > 0 ? CarnetTheme.inkSoft : CarnetTheme.inkMute)
                    }
                    .padding(.top, 9)

                    if let f = book.summarizedFraction {
                        HStack(spacing: 10) {
                            GridBar(value: f, width: 120, accentWhenFull: false)
                            GridLabel(book.isFullySummarized ? "Summarized" : "\(book.summarizedCount)/\(book.chapterCount)",
                                      size: 9.5, color: CarnetTheme.inkSoft)
                        }
                        .padding(.top, 8)
                    }
                } else {
                    GridLabel("Not extracted", size: 9.5, color: CarnetTheme.inkMute)
                        .padding(.top, 9)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.vertical, 15)
        .opacity(unavailable ? 0.5 : 1)
        .contentShape(Rectangle())
    }
}
