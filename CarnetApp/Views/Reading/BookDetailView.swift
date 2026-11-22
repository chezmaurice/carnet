import SwiftUI

/// One book — cover, stats, resume, highlights, and the full chapter list (no
/// separate chapters page). Port of the design's TBookDetail.
struct BookDetailView: View {
    let book: Book
    var previewChapters: [Chapter]? = nil
    var previewProgress: ReadingProgress? = nil
    var previewHighlightCount: Int = 0
    /// True when opened from the library while it's serving the offline cache —
    /// lets us skip a doomed network load for a book that was never cached.
    var libraryOffline: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var chapters: [Chapter] = []
    @State private var progress: ReadingProgress?
    @State private var highlightCount = 0
    @State private var loading = true
    @State private var error: String?
    @State private var summarizing = false
    @State private var pollTask: Task<Void, Never>?
    @State private var offline: OfflineState = .none
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadError: String?
    @State private var extracting = false
    @State private var showResonance = false
    @State private var showReading = false
    @State private var showMore = false
    @State private var confirmReset = false
    /// Mirrors the server's `enabled` column so the reader can honour a pause
    /// offline. Set from the loaded progress, and by the switch in the sheet.
    @State private var trackingPaused = false
    @State private var extractTask: Task<Void, Never>?
    @State private var extractError: String?
    /// Slugs whose content is cached on device — drives the per-row cache icon.
    /// Recomputed on appear and whenever the reader closes (reading caches more).
    @State private var cachedSlugs: Set<String> = []
    /// The reading companion bound to this book, if the member has one — a
    /// row of `maurices` of kind `companion`, whose pinned conversation the
    /// Maurice app opens at the reading position.
    @State private var companion: CompanionSummary?
    @State private var companionKnown = false
    @State private var followingBusy = false
    @State private var followError: String?

    private func refreshCachedSlugs() {
        cachedSlugs = Set(chapters.filter { BookCache.isChapterCached(bookId: book.id, slug: $0.slug) }.map(\.slug))
    }

    enum OfflineState: Equatable {
        case none
        case downloading(Int, Int)
        case downloaded(Int)   // size in bytes
    }

    private var summarizedCount: Int { chapters.filter(\.hasSummary).count }
    private var missingCount: Int { chapters.count - summarizedCount }
    private var summarizeFraction: Double {
        chapters.isEmpty ? 0 : Double(summarizedCount) / Double(chapters.count)
    }
    /// Where to resume — the local record (offline-capable, reconciled with the
    /// server on load) wins; the server progress is the fallback.
    private var resumeSlug: String? {
        ReadingPositionStore.get(bookId: book.id)?.chapterSlug ?? progress?.chapterSlug
    }
    private var resumeChapter: Chapter? {
        guard let slug = resumeSlug else { return nil }
        return chapters.first { $0.slug == slug }
    }
    /// Where "Resume" opens. The first chapter when nothing has been read, or
    /// when the recorded slug is not in this list any more.
    private var resumeIndex: Int { currentIndex ?? 0 }
    private var resumeMode: ReaderMode {
        if let v = ReadingPositionStore.get(bookId: book.id)?.lastView { return v == "summary" ? .summary : .full }
        return (progress?.isSummary ?? false) ? .summary : .full
    }
    /// How far in, over the list actually shown.
    ///
    /// NOT from `chapterIndex`, which is a different number: the server derives
    /// it from the chapter file's own `NNNN-` prefix, so it counts the front
    /// matter this list hides. Using it here put the reader several chapters
    /// ahead of where they were — a book whose first four files are skipped
    /// reported chapter 5 the moment you opened chapter 1. The slug is the only
    /// identity both sides agree on.
    private var readingFraction: Double? {
        guard resumeSlug != nil, let at = currentIndex else { return nil }
        return Double(at + 1) / Double(chapters.count)
    }

    /// Position of the chapter being read, in this list. Nil when nothing is
    /// being read, or when the slug is not one of these chapters (a re-extract
    /// can rename them).
    private var currentIndex: Int? {
        guard let slug = resumeSlug, !chapters.isEmpty else { return nil }
        return chapters.firstIndex { $0.slug == slug }
    }

    /// Pull a newer server position into the local store (another device read
    /// further); the local copy is what the reader restores from.
    private func reconcileReadingPosition() {
        guard !trackingPaused else { return }   // the marker is being held
        ReadingPositionStore.reconcile(bookId: book.id, with: progress)
    }

    var body: some View {
        Group {
            if loading {
                GridLoading()
            } else if let error {
                GridMessage(text: error)
            } else {
                content
            }
        }
        .background(CarnetTheme.bg)
        // Back floats alone at the top; the cover and the chapters scroll under it.
        .gridTopChrome { GridChromeRow { GridBackButton { dismiss() } } }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .onAppear { refreshCachedSlugs() }   // reflects chapters cached while reading
        .onDisappear { pollTask?.cancel() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header — cover + title + stats
                HStack(alignment: .top, spacing: 16) {
                    CoverImage(bookId: book.id, letter: book.coverLetter, width: 78, height: 110)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(book.title)
                            .font(CarnetTheme.display(22, weight: .bold))
                            .tracking(-0.4)
                            .foregroundStyle(CarnetTheme.ink)
                        Text(book.author)
                            .font(CarnetTheme.sans(13))
                            .foregroundStyle(CarnetTheme.inkMute)
                            .padding(.top, 4)
                        HStack(spacing: 20) {
                            stat("Chapters", "\(chapters.count)")
                            stat("Summarized", "\(summarizedCount)")
                        }
                        .padding(.top, 14)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 16)

                if chapters.isEmpty {
                    extractPrompt
                } else {
                    // Work in flight stays on the page: a download or a
                    // summarisation run is the one thing you want to watch, and
                    // it would be invisible behind the drawer that started it.
                    if let line = statusLine {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(CarnetTheme.inkMute)
                            GridLabel(line, size: 9.5, color: CarnetTheme.inkSoft)
                        }
                        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                        .padding(.bottom, 12)
                    }
                    if let downloadError {
                        Text(downloadError)
                            .font(CarnetTheme.mono(10))
                            .foregroundStyle(CarnetTheme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                            .padding(.bottom, 12)
                    }

                    // Full chapter list
                    GridLabel("Chapters")
                        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                        .padding(.bottom, 8)

                    ForEach(Array(chapters.enumerated()), id: \.element.id) { idx, ch in
                        GridRule()
                        NavigationLink(value: BookRoute.reader(book, chapters, idx,
                                                               ch.hasSummary && resumeMode == .summary ? .summary : .full)) {
                            ChapterRow(chapter: ch, index: idx + 1,
                                       isCurrent: ch.slug == progress?.chapterSlug,
                                       isRead: isRead(idx),
                                       isCached: cachedSlugs.contains(ch.slug))
                        }
                        .buttonStyle(.plain)
                    }
                    GridRule()
                }
            }
            .padding(.bottom, 24)
        }
        // The one thing you came here to do, always in reach — not scrolled
        // past the chapter list.
        .safeAreaInset(edge: .bottom) {
            if !chapters.isEmpty { resumeFooter }
        }
        // Declared here (with the links). HighlightsView deliberately opens the
        // reader via a cover, not a BookRoute link, to avoid a recursive
        // destination declaration (which crashes when the view is built).
        .navigationDestination(for: BookRoute.self) { route in
            switch route {
            case let .reader(b, chs, idx, mode):
                ReaderView(book: b, chapters: chs, startIndex: idx, mode: mode)
            case let .highlights(b, chs):
                HighlightsView(book: b, chapters: chs)
            }
        }
    }

    /// Rows before the one being read. Compared in this list's own positions —
    /// see readingFraction on why `chapterIndex` cannot be used for it.
    private func isRead(_ idx: Int) -> Bool {
        guard let cur = currentIndex else { return false }
        return idx < cur
    }

    // MARK: - Tool row + drawers
    //
    // The page used to stack a full-width card per function — resume,
    // highlights, resonance, offline, summarize — which pushed the chapter list
    // below the fold before the reading controls were even added. One glyph
    // each now, and the ones that need room open a drawer from the bottom that
    // a flick puts away.

    /// Round on the page, bare inside the glass footer (the footer draws the
    /// chrome there); `on` fills the accent circle on both.
    private func toolGlyph(_ symbol: String, on: Bool = false, dim: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16))
            .opacity(dim ? 0.4 : 1)
            .gridControlChrome(size: 44, on: on, round: true)
    }

    /// Every action the page offers, as one row of round buttons in the footer.
    /// Resume is filled: it is one of them, but it is the one you came for.
    private var actionRow: some View {
        // Spread, not packed: five 44pt buttons and four gaps come to 252pt,
        // which still leaves room inside the page margins on the narrowest
        // phone, and spaces out rather than clumping left on the widest.
        HStack(spacing: 0) {
            NavigationLink(value: BookRoute.reader(book, chapters, resumeIndex, resumeMode)) {
                toolGlyph("book", on: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(resumeChapter != nil ? "Resume" : "Start reading")

            Spacer(minLength: 8)

            NavigationLink(value: BookRoute.highlights(book, chapters)) {
                toolGlyph("highlighter", dim: highlightCount == 0)
            }
            .buttonStyle(.plain)
            .disabled(highlightCount == 0)
            .accessibilityLabel("Highlights")

            Spacer(minLength: 8)

            Button { showResonance = true } label: { toolGlyph("leaf") }
                .buttonStyle(.plain)
                .accessibilityLabel("Resonance")
                // On the button, not the outer view: presentation modifiers
                // stacked on one view fight for the slot and the sheet never shows.
                .sheet(isPresented: $showResonance) {
                    ResonanceSheet(sourceLabel: book.title, sourceBookTitle: book.title)
                }

            Spacer(minLength: 8)

            // Filled while paused, so a held marker is visible without opening
            // anything — it is the state most likely to surprise you later.
            Button { showReading = true } label: {
                toolGlyph(trackingPaused ? "pause.circle" : "bookmark", on: trackingPaused)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reading")
            .sheet(isPresented: $showReading) {
                readingDrawer
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }

            Spacer(minLength: 8)

            Button { showMore = true } label: { toolGlyph("ellipsis") }
                .buttonStyle(.plain)
                .accessibilityLabel("This book")
                .sheet(isPresented: $showMore) {
                    bookDrawer
                        .presentationDetents([.medium])
                        .presentationDragIndicator(.visible)
                }
        }
    }

    /// What is running, if anything — shown on the page, not in a drawer.
    private var statusLine: String? {
        if case .downloading(let d, let t) = offline { return "Downloading \(d)/\(t)…" }
        if summarizing { return "Summarizing \(summarizedCount)/\(chapters.count)…" }
        return nil
    }

    // MARK: - Reading drawer (where you are, and whether that is being tracked)

    private var readingDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            GridLabel("Reading")
            Text(currentIndex.map { "Chapter \($0 + 1) of \(chapters.count)" } ?? "Not started")
                .font(CarnetTheme.sans(16, weight: .semibold))
                .foregroundStyle(CarnetTheme.ink)
                .padding(.top, 7)
            if let ch = resumeChapter {
                Text(ch.title).font(CarnetTheme.sans(13)).foregroundStyle(CarnetTheme.inkMute)
                    .lineLimit(2).padding(.top, 2)
            }

            GridRule().padding(.vertical, 18)

            Toggle(isOn: Binding(get: { trackingPaused }, set: { setTrackingPaused($0) })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pause tracking").font(CarnetTheme.sans(14, weight: .medium))
                        .foregroundStyle(CarnetTheme.ink)
                    Text("Look up an index or a chapter further on without it counting as read.")
                        .font(CarnetTheme.sans(12)).foregroundStyle(CarnetTheme.inkMute)
                }
            }
            .tint(CarnetTheme.accent)

            Spacer(minLength: 18)

            Button(role: .destructive) { confirmReset = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 13))
                    Text("Reset progress").font(CarnetTheme.sans(14, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(CarnetTheme.accent)
                .padding(.horizontal, 16).padding(.vertical, 13)
                .overlay(Rectangle().strokeBorder(CarnetTheme.ruleHard, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(currentIndex == nil && !trackingPaused)
            // Losing your place in a long book is not something an undo gives back.
            .confirmationDialog("Forget where you are in this book?",
                                isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset progress", role: .destructive) { resetProgress() }
                Button("Cancel", role: .cancel) {}
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassSheetBackground()
    }

    /// Local first — the reader writes offline and the detail view resumes from
    /// the local record, so the device has to know before the server does.
    private func setTrackingPaused(_ paused: Bool) {
        trackingPaused = paused
        ReadingPositionStore.setPaused(paused, bookId: book.id)
        let id = book.id
        Task { _ = try? await CalibreAPI.setReadingTracking(bookId: id, paused: paused) }
    }

    private func resetProgress() {
        ReadingPositionStore.clear(bookId: book.id)
        progress = nil
        let id = book.id
        Task { try? await CalibreAPI.resetReadingProgress(bookId: id) }
    }

    // MARK: - Book drawer (offline copy, summaries)

    private var bookDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            GridLabel("This book")
            offlineRow.padding(.top, 12)
            if missingCount > 0 { summarizeBar.padding(.top, 16) }
            if companionKnown { companionRow.padding(.top, 16) }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassSheetBackground()
    }

    // MARK: - Resume footer

    private var resumeFooter: some View {
        Group {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(resumeChapter?.title ?? (chapters.first?.title ?? "—"))
                        .font(CarnetTheme.sans(13.5, weight: .semibold))
                        .foregroundStyle(CarnetTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let f = readingFraction {
                        GridLabel("\(Int(f * 100))%", size: 9.5, color: CarnetTheme.inkSoft)
                    }
                }
                if let f = readingFraction { GridBar(value: f) }
                actionRow.padding(.top, 3)
            }
            .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .glassFooter()
    }

    // MARK: - Extract (un-chaptered books)

    @ViewBuilder private var extractPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            GridLabel("Not split into chapters yet")
            Text("This book hasn't been chopped into chapters. Extract them to read and, optionally, summarize.")
                .font(CarnetTheme.sans(13.5))
                .foregroundStyle(CarnetTheme.inkSoft)
            if extracting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(CarnetTheme.inkMute)
                    GridLabel("Extracting chapters…", size: 9.5, color: CarnetTheme.inkSoft)
                }
                .padding(.top, 2)
            } else {
                GridButton(title: "Extract chapters", systemImage: "scissors", primary: true) {
                    extractTask = Task { await startExtract() }
                }
                .padding(.top, 2)
            }
            if let extractError {
                Text(extractError)
                    .font(CarnetTheme.caption)
                    .foregroundStyle(CarnetTheme.accent)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(CarnetTheme.surface)
        .overlay(Rectangle().strokeBorder(CarnetTheme.rule, lineWidth: 1))
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.top, 4)
    }

    private func startExtract() async {
        extracting = true; extractError = nil
        do {
            try await CalibreAPI.extract(bookId: book.id)
        } catch {
            extractError = "Couldn't start extraction.\n\(error.localizedDescription)"
            extracting = false
            return
        }
        // Poll until chapters appear or the server reports the job failed. The
        // job runs server-side; /status now surfaces its outcome so we can show
        // the real error instead of spinning forever.
        let bookId = book.id
        var attempts = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { return }
            if let chs = try? await CalibreAPI.chapters(bookId: bookId), !chs.isEmpty {
                await MainActor.run { chapters = chs; extracting = false }
                return
            }
            if let job = try? await CalibreAPI.status(bookId: bookId).job,
               job.state == .error {
                await MainActor.run {
                    extracting = false
                    extractError = "Extraction failed.\n\(job.error ?? "Unknown server error.")"
                }
                return
            }
            attempts += 1
            if attempts >= 40 {   // ~2 minutes
                await MainActor.run {
                    extracting = false
                    extractError = "Extraction didn't finish. Check the server, then try again."
                }
                return
            }
        }
    }

    // MARK: - Offline

    @ViewBuilder private var offlineRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle").font(.system(size: 15)).foregroundStyle(CarnetTheme.inkSoft)
            VStack(alignment: .leading, spacing: 2) {
                Text("Available offline").font(CarnetTheme.sans(14, weight: .medium)).foregroundStyle(CarnetTheme.ink)
                Text(offlineSubtitle).font(CarnetTheme.mono(9.5)).foregroundStyle(CarnetTheme.inkMute)
            }
            Spacer()
            switch offline {
            case .downloading(let d, let t):
                HStack(spacing: 8) {
                    GridLabel("\(d)/\(t)", size: 9.5, color: CarnetTheme.inkSoft)
                    ProgressView().controlSize(.small).tint(CarnetTheme.inkMute)
                }
            default:
                Toggle("", isOn: Binding(
                    get: { if case .downloaded = offline { return true } else { return false } },
                    set: { $0 ? startDownload() : removeOffline() }
                ))
                .labelsHidden()
                .tint(CarnetTheme.accent)
                .disabled(chapters.isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .overlay(Rectangle().strokeBorder(CarnetTheme.ruleHard, lineWidth: 1))
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.bottom, 16)
    }

    private var offlineSubtitle: String {
        switch offline {
        case .none: return "Not downloaded"
        case .downloading: return "Downloading…"
        case .downloaded(let bytes): return "\(chapters.count) chapters · \(BookCache.formatSize(bytes))"
        }
    }

    private func startDownload() {
        offline = .downloading(0, chapters.count)
        downloadError = nil
        let bookId = book.id, bk = book, chs = chapters
        downloadTask = Task {
            do {
                try await BookCache.download(book: bk, chapters: chs) { d, t in
                    offline = .downloading(d, t)
                }
                offline = .downloaded(BookCache.size(bookId: bookId))
                refreshCachedSlugs()   // light up every row
            } catch {
                if error.isCancellation { return }   // user toggled off / left
                BookCache.remove(bookId: bookId)      // clean up a partial download
                offline = .none
                downloadError = "Download didn't finish — tap to retry.\n\(error.localizedDescription)"
            }
        }
    }

    private func removeOffline() {
        downloadTask?.cancel()
        BookCache.remove(bookId: book.id)
        offline = .none
        refreshCachedSlugs()   // removing the download clears every row's cache icon
    }

    // MARK: - Summarize

    private var summarizeBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("\(missingCount) chapter\(missingCount == 1 ? "" : "s") need a summary")
                    .font(CarnetTheme.sans(13.5, weight: .semibold))
                    .foregroundStyle(CarnetTheme.ink)
                HStack(spacing: 9) {
                    GridBar(value: summarizeFraction, width: 120)
                    GridLabel("\(summarizedCount)/\(chapters.count)", size: 9.5, color: CarnetTheme.inkSoft)
                }
            }
            Spacer(minLength: 0)
            if summarizing {
                ProgressView().controlSize(.small).tint(CarnetTheme.inkMute)
            } else {
                GridButton(title: "All", systemImage: "sparkle", primary: true, small: true) {
                    Task { await startSummarize() }
                }
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .background(CarnetTheme.surface)
        .overlay(Rectangle().strokeBorder(CarnetTheme.rule, lineWidth: 1))
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.bottom, 16)
    }

    // MARK: - Reading companion (the book, followed by Maurice)

    /// Whether Maurice follows this book: a reading companion bound to it at
    /// the reading position, whose conversation lives in the Maurice app.
    /// Following it from here creates the row — `kind: companion`, never a
    /// domain — so the book's page is where the companion begins.
    @ViewBuilder private var companionRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.pages").font(.system(size: 15)).foregroundStyle(CarnetTheme.inkSoft)
            VStack(alignment: .leading, spacing: 2) {
                Text(companion == nil ? "Read with Maurice" : "Followed by Maurice")
                    .font(CarnetTheme.sans(14, weight: .medium)).foregroundStyle(CarnetTheme.ink)
                Text(companionSubtitle).font(CarnetTheme.mono(9.5)).foregroundStyle(CarnetTheme.inkMute)
                    .lineLimit(2)
            }
            Spacer()
            if followingBusy {
                ProgressView().controlSize(.small).tint(CarnetTheme.inkMute)
            } else if companion == nil {
                GridButton(title: "Follow", systemImage: "plus", small: true) { Task { await follow() } }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .overlay(Rectangle().strokeBorder(CarnetTheme.ruleHard, lineWidth: 1))
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.bottom, 16)
    }

    private var companionSubtitle: String {
        if let followError { return followError }
        guard let c = companion else {
            return "A companion follows your reading and talks about the book, in the Maurice app — no spoilers."
        }
        return c.conversation_id == nil
            ? "\(c.name) · conversation not started yet"
            : "\(c.name) · conversation in the Maurice app"
    }

    private func loadCompanion() async {
        guard let ov = try? await DomainsAPI.overview() else { return }
        companion = ov.companions.first { $0.bookId == book.id }
        companionKnown = true
    }

    private func follow() async {
        followingBusy = true; followError = nil
        defer { followingBusy = false }
        do {
            try await DomainsAPI.createCompanion(name: book.title, bookId: book.id)
            await loadCompanion()
        } catch {
            followError = "Couldn't follow: \(error.localizedDescription)"
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            GridLabel(label, size: 9)
            Text(value).font(CarnetTheme.sans(15, weight: .semibold)).foregroundStyle(CarnetTheme.ink)
        }
    }

    // MARK: - Data

    private func load() async {
        if BookCache.isDownloaded(bookId: book.id) {
            offline = .downloaded(BookCache.size(bookId: book.id))
        }
        if let previewChapters {
            chapters = previewChapters; progress = previewProgress
            highlightCount = previewHighlightCount; loading = false; refreshCachedSlugs(); return
        }
        #if DEBUG
        if ReadingPreview.active {
            chapters = Chapter.samples; progress = Chapter.sampleProgress
            highlightCount = Chapter.sampleHighlights.count; loading = false; return
        }
        #endif
        // Offline-first: render the cached chapter list immediately if we have it.
        let cached = BookCache.cachedChapters(bookId: book.id)
        if chapters.isEmpty, let cached, !cached.isEmpty {
            chapters = cached
            loading = false
            refreshCachedSlugs()
        }
        // Known offline with nothing cached — don't hang on the network for 15s.
        if libraryOffline && (cached?.isEmpty ?? true) {
            error = "This book isn't available offline.\nConnect to the internet to read it, or download it first."
            loading = false
            return
        }
        loading = chapters.isEmpty
        error = nil
        do {
            let fetched = try await CalibreAPI.chapters(bookId: book.id)
            chapters = fetched
            progress = try? await CalibreAPI.readingProgress(bookId: book.id)
            // The server holds the truth about tracking; mirror it on device so
            // the reader honours a pause set from another client, and offline.
            if let p = progress {
                trackingPaused = (p.enabled ?? 1) == 0
                ReadingPositionStore.setPaused(trackingPaused, bookId: book.id)
            } else {
                trackingPaused = ReadingPositionStore.isPaused(bookId: book.id)
            }
            reconcileReadingPosition()   // adopt a newer position from another device
            highlightCount = (try? await CalibreAPI.highlights(bookId: book.id).count) ?? 0
            refreshCachedSlugs()
            self.error = nil
            // Off the critical path: the drawer shows the row once it knows.
            Task { await loadCompanion() }
        } catch {
            if error.isCancellation { loading = false; return }   // view churn
            // Offline: fall back to the cached chapter list if we have one; a book
            // that's never been opened genuinely can't be read offline.
            if let cached = BookCache.cachedChapters(bookId: book.id), !cached.isEmpty {
                chapters = cached
                refreshCachedSlugs()
                self.error = nil
            } else {
                self.error = "This book isn't available offline.\nConnect to the internet to read it, or download it first."
            }
        }
        loading = false
    }

    private func startSummarize() async {
        summarizing = true
        do {
            try await CalibreAPI.summarize(bookId: book.id)
        } catch {
            self.error = error.localizedDescription; summarizing = false; return
        }
        pollTask?.cancel()
        let bookId = book.id
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                let st = try? await CalibreAPI.status(bookId: bookId)
                let refreshed = try? await CalibreAPI.chapters(bookId: bookId)
                let done = st?.isComplete == true
                    || (refreshed.map { !$0.isEmpty && $0.allSatisfy(\.hasSummary) } ?? false)
                if let job = st?.job, job.state == .error, !done {
                    await MainActor.run {
                        summarizing = false
                        error = "Summarization failed.\n\(job.error ?? "Unknown server error.")"
                    }
                    return
                }
                await MainActor.run {
                    if let refreshed { chapters = refreshed }
                    if done { summarizing = false }
                }
                if done { return }
            }
        }
    }
}

// MARK: - Route

enum BookRoute: Hashable {
    case reader(Book, [Chapter], Int, ReaderMode)
    case highlights(Book, [Chapter])
}

// MARK: - Chapter row (full list)

struct ChapterRow: View {
    let chapter: Chapter
    var index: Int? = nil
    var isCurrent: Bool = false
    var isRead: Bool = false
    var isCached: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            GridLabel(index.map { String(format: "%02d", $0) } ?? "•", size: 11)
                .frame(width: 18, alignment: .leading)
            Text(chapter.title)
                .font(CarnetTheme.sans(14))
                .foregroundStyle(isRead ? CarnetTheme.inkMute : CarnetTheme.ink)
                .lineLimit(2)
            Spacer(minLength: 8)
            if isCached {
                // On device — readable offline.
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 12)).foregroundStyle(CarnetTheme.inkMute)
            }
            if chapter.hasSummary {
                Image(systemName: "sparkle").font(.system(size: 13)).foregroundStyle(CarnetTheme.accent)
            }
            if isRead {
                Image(systemName: "checkmark").font(.system(size: 12)).foregroundStyle(CarnetTheme.inkMute)
            }
            if isCurrent {
                GridLabel("Now", size: 9, color: CarnetTheme.ink)
            }
        }
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.vertical, 13)
        .background(isCurrent ? CarnetTheme.surfaceAlt : Color.clear)
    }
}
