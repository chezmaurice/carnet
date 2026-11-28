import SwiftUI
import CryptoKit

/// Where the shelf's stack can go.
enum ShelfRoute: Hashable {
    case entry(ShelfEntry)
    /// An article's fiche, opened from its page.
    case fiche(ShelfEntry)
    /// Straight into the reader at the member's position in a book.
    case resume(bookId: Int, title: String, byline: String?)
    /// An article's captured text.
    case read(slug: String, locale: String)
    /// The captured text of an article given from another household and
    /// shared with the member: it lives in its owner's notes.
    case readShared(ShelfEntry)
    /// Every note, whatever it was written on.
    case notes
    case maurice
}

enum ShelfSort: String, GridSortChoice {
    case activity, title
    static var defaultChoice: ShelfSort { .activity }
    var label: String {
        switch self {
        case .activity: return "Last touched"
        case .title: return "Title"
        }
    }
}

/// Home — one list of entries of every kind: books, articles, films, series,
/// podcasts, games, posts. A row says, under the title, what the member has on
/// it (notes, a draft, a published piece) and, at the right, only when there
/// is something to read, where they are in it. The kinds are ticked in the
/// bottom panel, several at once; nothing is behind a mode.
///
/// What is not an entry — every note whatever it was written on, what Maurice
/// keeps on the member — is one tap away
/// under the member's button.
struct ShelfView: View {
    /// Opens the member/household sheet.
    var onIdentity: () -> Void = {}

    @State private var entries: [ShelfEntry] = []
    @State private var kinds: [ShelfResponse.KindCount] = []
    @State private var username = ""
    /// The member's public site, when they have one: publishing needs it.
    @State private var site: String?
    @State private var loading = true
    @State private var error: String?
    @State private var offlineCache = false
    @State private var didStartLoad = false
    /// A `carnet://entry/…` link being resolved.
    @State private var openingEntry = false
    @State private var searching = false
    @State private var query = ""
    @State private var menuOpen = false
    @State private var path = NavigationPath()
    /// The other half of the list: what was put away. Never cached, never the
    /// half the app opens on.
    @State private var showArchived = false
    @State private var pendingDelete: ShelfEntry?
    @State private var actionError: String?
    /// The « + »: a new entry in the member's own words.
    @State private var addingEntry = false
    @FocusState private var searchFocused: Bool

    /// Ticked kinds, comma-separated; empty shows everything.
    @AppStorage("carnet.shelf.kinds") private var kindsRaw = ""
    @AppStorage("carnet.shelf.sort") private var sortRaw = ShelfSort.defaultChoice.rawValue
    @Environment(CarnetRouter.self) private var router
    @Environment(CarnetSession.self) private var session

    private var ticked: Set<ShelfKind> {
        Set(kindsRaw.split(separator: ",").compactMap { ShelfKind(rawValue: String($0)) })
    }
    private var sort: ShelfSort { ShelfSort(rawValue: sortRaw) ?? .defaultChoice }

    private func toggle(_ kind: ShelfKind) {
        var set = ticked
        if set.contains(kind) { set.remove(kind) } else { set.insert(kind) }
        kindsRaw = ShelfKind.allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    if searching { searchField }
                    if loading {
                        GridLoading().frame(minHeight: 240)
                    } else if let error {
                        GridMessage(text: error)
                    } else {
                        list
                    }
                }
            }
            .refreshable { await fetch() }
            .overlay(alignment: .bottomTrailing) {
                if !searching {
                    AddEntryButton { addingEntry = true }
                        .padding(.trailing, CarnetTheme.pageHorizontalPadding)
                        .padding(.bottom, 16)
                }
            }
            .sheet(isPresented: $addingEntry) {
                // A row kept opens its entry, as a `carnet://entry/…` link does.
                AddEntrySheet { ref in router.openEntryId = ref }
            }
            .gridTopChrome {
                GridChromeRow {
                    Button { withAnimation(.easeOut(duration: 0.18)) { menuOpen.toggle() } } label: {
                        MemberBadge(member: session.activeMember, size: 30)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Menu")
                } trailing: {
                    GridIconButton(systemName: "magnifyingglass", primary: searching, size: 40) {
                        withAnimation(.easeOut(duration: 0.18)) { searching.toggle() }
                        searchFocused = searching
                        if !searching { query = "" }
                    }
                    .accessibilityLabel("Search")
                    GridSortMenu<ShelfSort>(raw: $sortRaw, size: 40)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { panel.glassFooter() }
            .overlay(alignment: .topLeading) { if menuOpen { menu } }
            .background(CarnetTheme.bg)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ShelfRoute.self) { route in
                // An entry's view is named by the entry: a `carnet://entry/…`
                // link replaces the stack with another entry at the same
                // depth, and SwiftUI would otherwise keep the open one's state
                // — and show the old entry.
                switch route {
                case let .entry(entry): EntryView(entry: entry, username: username, hasSite: site != nil).id(entry.id)
                case let .fiche(entry): EntryView(entry: entry, username: username, hasSite: site != nil, asFiche: true).id(entry.id)
                case let .resume(bookId, title, byline): BookResumeView(bookId: bookId, title: title, byline: byline)
                case let .read(slug, locale): ArticleReadView(slug: slug, locale: locale)
                case let .readShared(entry): ArticleReaderView(article: .shared(entry), entry: entry)
                case .notes: NotesView(open: { path.append(ShelfRoute.entry($0)) }, onBack: { path.removeLast() })
                case .maurice: DomainsShelfView(openBook: { path.append($0) }, onBack: { path.removeLast() })
                }
            }
            .confirmationDialog(
                pendingDelete.map { L("entry.delete.confirm", $0.title) } ?? "",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible, presenting: pendingDelete
            ) { entry in
                Button(L("entry.delete"), role: .destructive) { delete(entry) }
                Button(L("common.cancel"), role: .cancel) {}
            } message: { entry in
                Text(EntryView.deleteWarning(entry))
            }
            .alert(L("entry.action_failed"), isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button(L("common.ok"), role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
            .navigationDestination(for: Book.self) { BookDetailView(book: $0, libraryOffline: offlineCache) }
            .navigationDestination(for: Article.self) { ArticleDetailView(article: $0) }
            .navigationDestination(for: DomainSummary.self) { DomainBriefView(domain: $0) }
            .navigationDestination(for: OpenedConversationRoute.self) { OpenedConversationView(conversationId: $0.id) }
            .onAppear {
                guard !didStartLoad else { Task { await fetch() }; return }
                didStartLoad = true
                load()
            }
        }
        .task { await session.refreshMembers() }
        .task { await session.refreshHouseholdIdentities() }
        .task(id: session.activeMemberId) { await session.refreshLanguage() }
        .task { openPendingConversation() }
        .onChange(of: router.openConversationId) { _, _ in openPendingConversation() }
        .task { openPendingEntry() }
        .onChange(of: router.openEntryId) { _, _ in openPendingEntry() }
    }

    /// A `carnet://entry/…` link lands here: the entry is pushed on top of
    /// the list. It may be a minute old — kept from a conversation in the
    /// Maurice app — and the app may just be waking, its network not yet
    /// back: the entry is asked for by name, a few times, rather than looked
    /// for once in a list that may not hold it yet. The link is let go only
    /// once handled, so a list rebuilt meanwhile takes it up.
    private func openPendingEntry() {
        guard let ref = router.openEntryId, !openingEntry else { return }
        openingEntry = true
        Task {
            defer { openingEntry = false }
            let entry = await entryNamed(ref)
            if router.openEntryId == ref { router.openEntryId = nil }
            guard let entry else { return }
            path = NavigationPath()
            path.append(ShelfRoute.entry(entry))
            // The list learns of it too.
            await fetch()
        }
    }

    private func entryNamed(_ ref: String) async -> ShelfEntry? {
        let find = { entries.first { $0.id == ref || $0.translations.contains { $0.id == ref } } }
        if let entry = find() { return entry }
        // A book just added to the library (`calibre/<id>`) has no page of
        // its own to ask for: it is in the list once the list is read again.
        if ref.hasPrefix("calibre/") {
            for wait in [0.0, 1.0, 2.5] {
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                await fetch()
                if let entry = find() { return entry }
            }
            return nil
        }
        let parts = ref.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        for wait in [0.0, 0.7, 1.5, 3.0] {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if let entry = find() { return entry }
            if let page = try? await GardenAPI.entryPage(collection: parts[0], locale: parts[1], slug: parts[2]) {
                return page.entry
            }
        }
        return nil
    }

    /// A notification tap lands here: the conversation Maurice opened is
    /// pushed on top of whatever was showing.
    private func openPendingConversation() {
        guard let id = router.openConversationId else { return }
        router.openConversationId = nil
        path = NavigationPath()
        path.append(ShelfRoute.maurice)
        path.append(OpenedConversationRoute(id: id))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                GridLabel(kicker)
                Spacer(minLength: 0)
                if showArchived {
                    Button { setShowArchived(false) } label: {
                        GridLabel("Back to the list", color: CarnetTheme.ink).underline()
                    }
                    .buttonStyle(.plain)
                } else if !ticked.isEmpty {
                    Button { kindsRaw = "" } label: {
                        GridLabel("Show all", color: CarnetTheme.ink).underline()
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Carnet")
                .font(CarnetTheme.headerTitle)
                .tracking(CarnetTheme.headerTitleTracking)
                .foregroundStyle(CarnetTheme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private var kicker: String {
        if loading { return showArchived ? "Archived" : "Everything" }
        let kindsShown = ticked.isEmpty ? "Everything"
            : ShelfKind.allCases.filter(ticked.contains).map(\.label).joined(separator: ", ")
        let scope = showArchived ? (ticked.isEmpty ? "Archived" : "Archived · \(kindsShown)") : kindsShown
        return "\(offlineCache ? "Offline · " : "")\(scope) · \(visible.count)"
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(CarnetTheme.inkMute)
            TextField("Title or author", text: $query)
                .font(CarnetTheme.sans(15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .submitLabel(.search)
            if searchFocused && query.isEmpty { HideKeyboardButton(focus: $searchFocused) }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Capsule().fill(CarnetTheme.surface))
        .overlay(Capsule().strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.bottom, 14)
    }

    // MARK: - List

    private var visible: [ShelfEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let kept = entries.filter { e in
            (ticked.isEmpty || ticked.contains(e.kind))
                && (q.isEmpty || e.title.lowercased().contains(q) || (e.byline ?? "").lowercased().contains(q))
        }
        switch sort {
        // The server's own order: what was last written on or read, first.
        case .activity: return kept
        case .title: return kept.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            GridRule()
            if visible.isEmpty {
                Text(!entries.isEmpty ? "Nothing matches." : showArchived ? "Nothing archived." : "Nothing here yet.")
                    .font(CarnetTheme.caption)
                    .foregroundStyle(CarnetTheme.inkHint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { entry in
                        // Right puts the row away (or brings it back, among
                        // the archived); left deletes it. A book of the
                        // library with no entry has nothing to delete.
                        SwipeRow(
                            leading: SwipeAction(
                                title: L(showArchived ? "entry.unarchive" : "entry.archive"),
                                systemImage: showArchived ? "tray.and.arrow.up" : "archivebox",
                                tint: CarnetTheme.ink
                            ) { archive(entry) },
                            // Nor has another member's entry, shared with
                            // this one: it is theirs to delete.
                            trailing: entry.isLibraryOnly || entry.isForeign ? nil : SwipeAction(
                                title: L("entry.delete"), systemImage: "trash", tint: .red
                            ) { pendingDelete = entry }
                        ) {
                            path.append(ShelfRoute.entry(entry))
                        } content: {
                            ShelfRow(entry: entry)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bottom panel (continue · the kinds to show)

    /// What the member was last reading and has not finished.
    private var reading: ShelfEntry? {
        entries
            .filter { $0.source?.progress != nil && !($0.source?.progress?.finished ?? true) }
            .max { ($0.source?.progress?.updatedAt ?? "") < ($1.source?.progress?.updatedAt ?? "") }
    }

    private var panel: some View {
        VStack(spacing: 10) {
            if let entry = reading, let bookId = entry.source?.bookId {
                HStack(spacing: 12) {
                    CoverImage(shelf: entry, width: 28, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        GridLabel("Continue · \(entry.source?.progress?.chapterTitle ?? "")", size: 9.5).lineLimit(1)
                        Text(entry.title)
                            .font(CarnetTheme.sans(14, weight: .medium))
                            .foregroundStyle(CarnetTheme.ink)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    GridButton(title: "Resume", systemImage: "book", primary: true, small: true) {
                        path.append(ShelfRoute.resume(bookId: bookId, title: entry.title, byline: entry.byline))
                    }
                }
                .padding(.horizontal, 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(kinds, id: \.kind) { k in
                        Button { toggle(k.kind) } label: {
                            KindChip(label: k.kind.label, count: k.count, on: ticked.contains(k.kind))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .padding(.vertical, 12)
    }

    // MARK: - Member menu (what is not an entry)

    private var menu: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { menuOpen = false } }
            VStack(alignment: .leading, spacing: 0) {
                Button { menuOpen = false; onIdentity() } label: {
                    HStack(spacing: 11) {
                        MemberBadge(member: session.activeMember, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.activeMember?.display_name ?? "Sign in")
                                .font(CarnetTheme.sans(15, weight: .semibold))
                                .foregroundStyle(CarnetTheme.ink)
                            GridLabel(session.currentHouseholdName, size: 9)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11)).foregroundStyle(CarnetTheme.inkMute)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                GridRule().padding(.horizontal, 14)
                menuRow("Entries", system: "doc.text", count: entries.isEmpty || showArchived ? nil : "\(entries.count)", current: !showArchived) {
                    menuOpen = false
                    setShowArchived(false)
                }
                menuRow("Archived", system: "archivebox", count: nil, current: showArchived) {
                    menuOpen = false
                    setShowArchived(!showArchived)
                }
                menuRow("Notes", system: "note.text", count: nil, current: false) {
                    menuOpen = false
                    path.append(ShelfRoute.notes)
                }
                menuRow("Maurice", system: "bubble.left", count: nil, current: false) {
                    menuOpen = false
                    path.append(ShelfRoute.maurice)
                }
            }
            .padding(.bottom, 6)
            .frame(width: 250)
            .glassCard()
            .padding(.leading, 12)
            .padding(.top, 50)
        }
        .transition(.opacity)
    }

    private func menuRow(_ title: String, system: String, count: String?, current: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: system).font(.system(size: 15)).frame(width: 20)
                Text(title).font(CarnetTheme.sans(15, weight: current ? .semibold : .regular))
                Spacer(minLength: 0)
                if let count { GridLabel(count, size: 9.5) }
            }
            .foregroundStyle(CarnetTheme.ink)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background {
                if current {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(CarnetTheme.rule)
                }
            }
            .padding(.horizontal, 6).padding(.top, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Loading (cache-first, like the shelves before it)

    // MARK: - Putting away, deleting

    private func setShowArchived(_ on: Bool) {
        guard on != showArchived else { return }
        showArchived = on
        entries = []
        kinds = []
        if !on, let cached = ShelfCache.cached() { apply(cached) }
        loading = entries.isEmpty
        Task { await fetch() }
    }

    /// The row leaves at once; the server is told, and the list read again so
    /// the counts follow. If it refused, the list comes back as it is there.
    private func archive(_ entry: ShelfEntry) {
        let on = !showArchived
        withAnimation(.easeOut(duration: 0.2)) { entries.removeAll { $0.id == entry.id } }
        Task {
            do { try await GardenAPI.setArchived(entry, on) }
            catch { actionError = EntryView.message(error) }
            await fetch()
        }
    }

    private func delete(_ entry: ShelfEntry) {
        withAnimation(.easeOut(duration: 0.2)) { entries.removeAll { $0.id == entry.id } }
        Task {
            do { try await GardenAPI.deleteEntry(entry) }
            catch { actionError = EntryView.message(error) }
            await fetch()
        }
    }

    private func load() {
        if entries.isEmpty, !showArchived, let cached = ShelfCache.cached() {
            apply(cached)
            offlineCache = true
            loading = false
        }
        Task { await fetch() }
    }

    private func apply(_ response: ShelfResponse) {
        entries = response.entries
        kinds = response.kinds
        username = response.garden.username
        site = response.garden.site
    }

    private func fetch() async {
        do {
            let asked = showArchived
            let response = try await GardenAPI.shelf(archived: asked)
            // The half asked for may no longer be the one on screen.
            guard asked == showArchived else { return }
            apply(response)
            if !asked { ShelfCache.cache(response) }
            offlineCache = false
            error = nil
            loading = false
        } catch {
            if error.isCancellation {
                if entries.isEmpty { didStartLoad = false }
                loading = false
                return
            }
            if !showArchived, let cached = ShelfCache.cached() {
                apply(cached)
                offlineCache = true
                self.error = nil
            } else if entries.isEmpty {
                self.error = "Couldn't load your entries.\n\(error.localizedDescription)"
            }
            loading = false
        }
    }
}

// MARK: - Swiping a row

struct SwipeAction {
    let title: String
    let systemImage: String
    let tint: Color
    let perform: () -> Void
}

/// A row that slides aside: to the right for `leading`, to the left for
/// `trailing`, done on release once past the threshold. The list is a
/// `LazyVStack` in a `ScrollView`, not a `List`, so the system's swipe actions
/// are not to be had; this is the same gesture, by hand. The drag runs beside
/// the scroll view's own and only takes a movement that is clearly sideways.
///
/// The row is opened by the tap this view owns, not by a button inside it. A
/// button fires on any touch that ends within it, however far the finger
/// travelled sideways in between: wrapped around a `NavigationLink`, every
/// swipe ended by opening the entry. A tap is refused once the finger has
/// moved, which is the difference that matters here. (A long-press menu was
/// dropped for the same reason: holding while dragging raised its preview.)
struct SwipeRow<Content: View>: View {
    var leading: SwipeAction?
    var trailing: SwipeAction?
    var onTap: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    /// nil until the drag has said which way it goes.
    @State private var sideways: Bool?
    @State private var armed = false

    private let threshold: CGFloat = 96

    private var action: SwipeAction? { offset > 0 ? leading : offset < 0 ? trailing : nil }

    var body: some View {
        content()
            .background(CarnetTheme.bg)
            .offset(x: offset)
            .background {
                if let action {
                    HStack(spacing: 8) {
                        if offset < 0 { Spacer(minLength: 0) }
                        Image(systemName: action.systemImage).font(.system(size: 17, weight: .medium))
                        Text(action.title).font(CarnetTheme.sans(14, weight: .medium))
                        if offset > 0 { Spacer(minLength: 0) }
                    }
                    .foregroundStyle(action.tint == CarnetTheme.ink ? CarnetTheme.bg : Color.white)
                    .scaleEffect(armed ? 1.08 : 1, anchor: offset > 0 ? .leading : .trailing)
                    .padding(.horizontal, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(action.tint.opacity(armed ? 1 : 0.55))
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { if offset == 0 { onTap() } }
            .accessibilityAddTraits(.isButton)
            .simultaneousGesture(
                DragGesture(minimumDistance: 16)
                    .onChanged { value in
                        let dx = value.translation.width, dy = value.translation.height
                        if sideways == nil { sideways = abs(dx) > abs(dy) * 1.6 }
                        guard sideways == true else { return }
                        // A side with nothing behind it gives a little and no more.
                        let allowed = (dx > 0 && leading != nil) || (dx < 0 && trailing != nil)
                        offset = allowed ? dx : dx / 6
                        let nowArmed = allowed && abs(dx) > threshold
                        if nowArmed != armed {
                            armed = nowArmed
                            if nowArmed { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                        }
                    }
                    .onEnded { _ in
                        let fire = armed ? action : nil
                        sideways = nil
                        armed = false
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = 0 }
                        fire?.perform()
                    }
            )
            .accessibilityActions {
                if let leading { Button(leading.title, action: leading.perform) }
                if let trailing { Button(trailing.title, action: trailing.perform) }
            }
    }
}

// MARK: - Row

/// One entry in the list. Under the title: the member's sides, in words and
/// marks. At the right, only when there is something to read: where they are.
struct ShelfRow: View {
    let entry: ShelfEntry

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            CoverImage(shelf: entry, width: 52, height: entry.kind.squareCover ? 52 : 74)
                .clipShape(RoundedRectangle(cornerRadius: CarnetTheme.coverCornerRadius, style: .continuous))
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(CarnetTheme.sans(15, weight: .medium))
                        .foregroundStyle(CarnetTheme.ink)
                        .lineLimit(2)
                    Text(entry.kindLine)
                        .font(CarnetTheme.sans(13))
                        .foregroundStyle(CarnetTheme.inkSoft)
                        .lineLimit(1)
                    StateLine(entry: entry).padding(.top, 5)
                }
                Spacer(minLength: 0)
                SourceColumn(source: entry.source)
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 74 + 28, alignment: .leading)
            .overlay(alignment: .bottom) { GridRule() }
        }
        .padding(.leading, CarnetTheme.pageHorizontalPadding)
        .padding(.trailing, CarnetTheme.pageHorizontalPadding)
        .contentShape(Rectangle())
    }
}

/// "15 notes · ○ Draft" — or "Not opened" when nothing of the member's is there.
struct StateLine: View {
    let entry: ShelfEntry

    var body: some View {
        if let from = entry.source?.sharedBy, entry.isUntouched {
            // A copy someone gave, not yet written on: who gave it says more
            // than « Not opened ».
            GridLabel(from.line, size: 9.5, color: CarnetTheme.inkSoft)
        } else if entry.isUntouched, !entry.isShared {
            GridLabel("Not opened", size: 9.5, color: CarnetTheme.inkHint)
        } else {
            HStack(spacing: 7) {
                // Who else writes on it: its owner when it is someone else's,
                // the members it is shared with when it is the reader's own.
                if entry.isShared { AvatarStack(people: entry.people, size: 16) }
                if entry.noteCount > 0 {
                    GridLabel("\(entry.noteCount) \(entry.noteCount == 1 ? "note" : "notes")", size: 9.5)
                }
                if entry.noteCount > 0, entry.shared != nil {
                    GridLabel("·", size: 9.5)
                }
                if let shared = entry.shared { StateMark(state: shared.state.mark) }
            }
        }
    }
}

/// The right edge of a row: present only when the entry can be read.
struct SourceColumn: View {
    let source: ShelfSource?

    var body: some View {
        if let source {
            if source.isBook {
                let p = source.progress
                VStack(alignment: .trailing, spacing: 6) {
                    GridLabel(p == nil ? "Unread" : p!.finished ? "Read" : "\(Int((p!.fraction * 100).rounded())) %",
                              size: 9.5, color: p == nil ? CarnetTheme.inkMute : CarnetTheme.ink)
                    GridBar(value: p?.fraction ?? 0, width: 44, accentWhenFull: false)
                }
                .frame(width: 52, alignment: .trailing)
            } else if source.captured ?? false {
                GridLabel("\(source.readingMinutes ?? 1) min", size: 9.5, color: CarnetTheme.ink)
                    .frame(width: 52, alignment: .trailing)
            } else {
                GridLabel("Link only", size: 9.5)
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }
}

/// A kind to tick. Ticked is an ink outline and a check, not a fill: the fill
/// is the primary action's.
struct KindChip: View {
    let label: String
    let count: Int
    let on: Bool

    var body: some View {
        HStack(spacing: 5) {
            if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
            Text(label).font(CarnetTheme.sans(13, weight: on ? .semibold : .regular))
            Text("\(count)").font(CarnetTheme.mono(9.5)).foregroundStyle(CarnetTheme.inkMute)
        }
        .foregroundStyle(on ? CarnetTheme.ink : CarnetTheme.inkSoft)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .overlay(Capsule().strokeBorder(on ? CarnetTheme.ink : Color.clear, lineWidth: 1.25))
        .contentShape(Capsule())
    }
}

// MARK: - Cache (offline browsing)

/// Last-seen shelf, in the signed-in member's folder (MemberStore).
enum ShelfCache {
    private static var url: URL? { MemberStore.file("shelf.json") }

    static func cache(_ response: ShelfResponse) {
        guard let url else { return }
        try? JSONEncoder().encode(response).write(to: url, options: .atomic)
    }
    static func cached() -> ShelfResponse? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ShelfResponse.self, from: data)
    }
}
