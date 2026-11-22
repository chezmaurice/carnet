import SwiftUI

/// The Articles shelf of the Reading section — every article captured through
/// the share sheet or the browser clipper, straight from the garden. Same
/// chrome and offline behaviour as the books list it sits beside.
struct ArticlesShelfView: View {
    /// Opens the app drawer (shown as ☰ in the header when hosted in the shell).
    var onMenu: (() -> Void)? = nil
    /// Opens the member/household sheet (member badge in the header, minimal scope).
    var onIdentity: (() -> Void)? = nil
    /// Which shelf the Reading section shows — bound so the toggle can switch back.
    @Binding var shelf: ReadingShelf

    @State private var articles: [Article] = []
    @State private var loading = true
    @State private var error: String?
    @State private var filter: ArticleFilter = .all
    @State private var searching = false
    @State private var query = ""
    @State private var didStartLoad = false
    /// True when the list is served from the on-device cache (server unreachable).
    @State private var offlineCache = false

    var body: some View {
        // Same floating chrome as the books shelf: identity left, filter
        // right, search in the bottom bar; title and toggle scroll beneath.
        ScrollView {
            VStack(spacing: 0) {
                GridTitle(title: "Library",
                          kicker: loading ? "Notes" : (offlineCache ? "Offline · \(articles.count)" : "Notes · \(articles.count)"))
                ShelfToggle(shelf: $shelf)
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
                Menu {
                    Picker("Filter", selection: $filter) {
                        ForEach(ArticleFilter.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    GridIconGlyph(systemName: "line.3.horizontal.decrease", on: filter != .all, size: 32)
                }
                .accessibilityLabel("Filter")
            }
        }
        .gridBottomChrome {
            GridSearchBar(searching: $searching, query: $query, placeholder: "Search title or publication")
        }
        .onAppear {
            // Coming back from a detail: a note may have opened the fiche, a
            // summary may have landed — the rows say so only if we ask again.
            guard !didStartLoad else { Task { await fetch() }; return }
            didStartLoad = true
            load()
        }
    }

    private var content: some View {
        Group {
            VStack(spacing: 0) {
                if filter != .all {
                    HStack(spacing: 8) {
                        GridLabel(filter.label, size: 9.5, color: CarnetTheme.inkSoft)
                        Spacer(minLength: 0)
                        Button { filter = .all } label: {
                            GridLabel("Clear", size: 9.5, color: CarnetTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                }

                GridRule()

                if visibleArticles.isEmpty {
                    Text("No articles")
                        .font(CarnetTheme.caption)
                        .foregroundStyle(CarnetTheme.inkHint)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                } else {
                    // Lazy, like the garden's list: an eager stack starts every
                    // row's cover fetch the moment the shelf lands.
                    LazyVStack(spacing: 0) {
                        ForEach(visibleArticles) { article in
                            NavigationLink(value: article) {
                                ArticleRow(article: article,
                                           cached: ArticleCache.hasText(article),
                                           offline: offlineCache)
                            }
                            .buttonStyle(.plain)
                            GridRule()
                        }
                    }
                }
            }
        }
    }

    private var visibleArticles: [Article] {
        articles.filter { filter.matches($0) }
            .filter { a in
                guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
                let q = query.lowercased()
                return a.title.lowercased().contains(q)
                    || (a.publication ?? "").lowercased().contains(q)
            }
    }

    private func load() {
        // Cache-first, like the books list: show the last-seen list immediately,
        // replace it when the server answers.
        if articles.isEmpty, let cached = ArticleCache.cachedList(), !cached.isEmpty {
            articles = cached
            offlineCache = true
            loading = false
        }
        Task { await fetch() }
    }

    private func fetch() async {
        do {
            let fetched = try await GardenAPI.articles()
            articles = fetched
            ArticleCache.cacheList(fetched)
            offlineCache = false
            error = nil
            loading = false
        } catch {
            if error.isCancellation {
                if articles.isEmpty { didStartLoad = false }
                loading = false
                return
            }
            if let cached = ArticleCache.cachedList(), !cached.isEmpty {
                articles = cached
                offlineCache = true
                self.error = nil
            } else if articles.isEmpty {
                self.error = "Couldn't load your articles.\n\(error.localizedDescription)"
            }
            loading = false
        }
    }
}

// MARK: - Filter

enum ArticleFilter: String, CaseIterable, Identifiable {
    case all, fiches, unread, summarized, bookmarks
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .fiches: return "Fiches (written on)"
        case .unread: return "Not summarized"
        case .summarized: return "Summarized"
        case .bookmarks: return "Bookmarks (not captured)"
        }
    }

    func matches(_ a: Article) -> Bool {
        switch self {
        case .all: return true
        case .fiches: return a.isOpened
        case .unread: return !a.isBookmarkOnly && !a.hasSummary
        case .summarized: return a.hasSummary
        case .bookmarks: return a.isBookmarkOnly
        }
    }
}

// MARK: - Row

private struct ArticleRow: View {
    let article: Article
    var cached: Bool = false
    var offline: Bool = false

    /// Offline, an article with no on-device copy can't be read — dim it.
    private var unavailable: Bool { offline && !cached }

    var body: some View {
        HStack(spacing: 14) {
            CoverImage(article: article)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(article.title)
                        .font(CarnetTheme.sans(15.5, weight: .semibold))
                        .tracking(-0.15)
                        .foregroundStyle(CarnetTheme.ink)
                        .lineLimit(2)
                    if cached {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(CarnetTheme.inkMute)
                    }
                }
                Text(article.bylineShort)
                    .font(CarnetTheme.sans(12.5))
                    .foregroundStyle(CarnetTheme.inkMute)
                    .padding(.top, 2)
                    .lineLimit(1)

                // The capture indication the row promises: readable here, or not.
                if unavailable {
                    GridLabel("Unavailable offline", size: 9.5, color: CarnetTheme.inkMute)
                        .padding(.top, 9)
                } else if article.isBookmarkOnly {
                    HStack(spacing: 14) {
                        GridLabel("Not captured · bookmark", size: 9.5, color: CarnetTheme.inkMute)
                        if article.isOpened { GridLabel("Fiche", size: 9.5, color: CarnetTheme.inkSoft) }
                    }
                    .padding(.top, 9)
                } else {
                    HStack(spacing: 14) {
                        GridLabel("Text · \(article.readingMinutes) min", size: 9.5)
                        if article.hasSummary {
                            GridLabel("Summarized", size: 9.5, color: CarnetTheme.inkSoft)
                        }
                        if let n = article.highlightCount, n > 0 {
                            GridLabel("\(n) hl", size: 9.5, color: CarnetTheme.inkSoft)
                        }
                        // Same badge the Garden list uses — only once it is one.
                        if article.isOpened { GridLabel("Fiche", size: 9.5, color: CarnetTheme.inkSoft) }
                    }
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
