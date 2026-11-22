import SwiftUI

/// Chapter reader — full text ⇄ summary, adjustable type, chapter nav, and a
/// chapter-level bookmark + note (v1 stand-in for passage highlights). Port of
/// the design's TReader. Persists reading position on the server as you move.
struct ReaderView: View {
    let book: Book
    let chapters: [Chapter]
    @State private var index: Int
    @State private var view: ReaderMode

    // Offline/preview injection.
    var previewText: String? = nil
    var previewSummary: String? = nil
    var previewHighlights: [Highlight]? = nil

    @Environment(\.dismiss) private var dismiss
    @AppStorage("carnet.reader.fontSize") private var fontRaw = ReaderFontSize.medium.rawValue

    @State private var text: String = ""
    @State private var loading = true
    @State private var error: String?
    @State private var bookmarkId: Int?
    @State private var note: String = ""
    @State private var showNote = false
    @State private var takingNote = false
    @State private var highlights: [Highlight] = []
    @State private var editor: HLEditor?
    /// A conversation with Maurice being opened from here, and why it could not.
    @State private var openingMaurice = false
    @State private var mauriceFailure: String?

    // Exact reading-position tracking (synced + offline). Full text saves the top
    // visible character index; the summary saves the top paragraph index. `pos`
    // is a reference box so per-scroll updates don't re-render the reader.
    @State private var restoreCharIndex: Int = 0
    @State private var pos = PositionBox()
    @State private var saveTask: Task<Void, Never>?
    /// The bars step aside while the reader reads on, and come back when
    /// they scroll back up.
    @State private var chromeHidden = false

    private final class PositionBox { var fullChar = 0; var summaryPara = 0 }


    private enum HLEditor: Identifiable {
        case new(NSRange, String)
        case edit(Highlight)
        var id: String {
            switch self {
            case let .new(r, _): return "new-\(r.location)-\(r.length)"
            case let .edit(h): return "edit-\(h.id)"
            }
        }
    }

    private var chapterHighlights: [Highlight] {
        // Both texts' highlights arrive together; each view shows its own, since
        // the offsets only mean anything against the text they were taken from.
        highlights.filter { $0.chapterSlug == chapter.slug && $0.readerView == view.apiValue }
    }

    init(book: Book, chapters: [Chapter], startIndex: Int = 0, mode: ReaderMode = .full,
         previewText: String? = nil, previewSummary: String? = nil, previewHighlights: [Highlight]? = nil) {
        self.book = book
        self.chapters = chapters
        self._index = State(initialValue: max(0, min(startIndex, chapters.count - 1)))
        self._view = State(initialValue: mode)
        self.previewText = previewText
        self.previewSummary = previewSummary
        self.previewHighlights = previewHighlights
    }

    private var chapter: Chapter { chapters[index] }
    private var font: ReaderFontSize { ReaderFontSize(rawValue: fontRaw) ?? .medium }
    private var isBookmarked: Bool { bookmarkId != nil }
    private var progress: Double {
        chapters.isEmpty ? 0 : Double(index + 1) / Double(chapters.count)
    }

    var body: some View {
        // The text runs the whole height of the screen and scrolls beneath
        // the chrome, as in the article reader: the controls float at the top,
        // the panel at the bottom, and both step aside while the reader reads on.
        content
            .gridTopChrome { topBar.readerChrome(hidden: chromeHidden, edge: .top) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomPanel.glassFooter().readerChrome(hidden: chromeHidden, edge: .bottom)
            }
            .background(CarnetTheme.bg)
            .onChange(of: index) { _, _ in showChrome() }
            .onChange(of: view) { _, _ in showChrome() }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: TaskKey(index: index, mode: view)) { await loadChapter() }
        .onDisappear { flushPositionSave() }
        .sheet(isPresented: $showNote) { noteSheet }
        .sheet(isPresented: $takingNote) {
            NoteSheet(title: book.title, chapterTitle: chapter.title) { text, _, _ in
                guard previewText == nil, previewSummary == nil else { return }
                try await GardenAPI.addBookNote(bookId: book.id, text: text, chapterTitle: chapter.title)
            }
        }
        .sheet(item: $editor) { ed in editorSheet(ed) }
        .overlay { if openingMaurice { ProgressView().tint(CarnetTheme.inkMute) } }
        .alert("Maurice could not be opened",
               isPresented: Binding(get: { mauriceFailure != nil }, set: { if !$0 { mauriceFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(mauriceFailure ?? "")
        }
    }

    @ViewBuilder private func editorSheet(_ ed: HLEditor) -> some View {
        switch ed {
        case let .new(range, quote):
            HighlightEditorSheet(quote: quote, color: "yellow", note: "", isEditing: false,
                resonance: ResonanceSource(label: book.title, bookTitle: book.title),
                onSave: { color, note in createHighlight(range: range, quote: quote, color: color, note: note) },
                onTalk: { color, note in createHighlight(range: range, quote: quote, color: color, note: note, talk: true) })
        case let .edit(h):
            HighlightEditorSheet(quote: h.quote, color: h.color, note: h.note ?? "", isEditing: true,
                onSave: { color, note in updateHighlight(h, color: color, note: note) },
                onDelete: { deleteHighlight(h) },
                conversation: h.conversation,
                onTalk: { color, note in
                    if color != h.color || note != (h.note ?? "") { updateHighlight(h, color: color, note: note) }
                    talkToMaurice(highlight: h.id)
                })
        }
    }

    // MARK: - Top bar

    // Back alone at the leading edge; type size and the chapter's bookmark
    // together in one capsule at the trailing edge. What acts on the reading
    // itself (text or summary, chapter, note) is in the bottom panel.
    private var topBar: some View {
        GridChromeRow {
            GridBackButton(size: 40) { flushPositionSave(); dismiss() }
        } trailing: {
            ReaderFontButton(raw: $fontRaw)
            Button { toggleBookmark() } label: {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 16))
                    .gridControlChrome(size: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isBookmarked ? "Remove bookmark" : "Bookmark this chapter")
        }
    }

    // MARK: - Content

    private var content: some View {
        Group {
            if loading {
                GridLoading()
            } else if let error {
                GridMessage(text: error)
            } else if view == .full {
                fullContent
            } else {
                summaryContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // The chapter's heading: the first thing in the text's own flow, not a
    // band pinned above it — held on screen it took a fifth of the page.
    private var chapterHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReaderHeading(eyebrow: "\(book.title) · \(book.author)", title: chapter.title, meta: chapterMeta,
                          titleLines: 6, inset: 0)
            GridRule()
        }
        .padding(.bottom, 16)
    }

    private func showChrome() {
        guard chromeHidden else { return }
        withAnimation(.easeOut(duration: 0.22)) { chromeHidden = false }
    }

    private func followChrome(_ visible: Bool) {
        withAnimation(.easeOut(duration: 0.22)) { chromeHidden = !visible }
    }

    private var chapterMeta: String {
        let n = chapterHighlights.count
        let marks = n == 0 ? "" : " · \(n) highlight\(n == 1 ? "" : "s")"
        return "\(chapter.readingMinutes) min\(marks)"
    }

    // Full text: highlightable, with an inline "Highlight" menu. The UIKit
    // scroll view owns scrolling so position restores exactly; the bars'
    // heights are read here and handed to it, and it runs beneath them.
    private var fullContent: some View {
        GeometryReader { proxy in
            HighlightableText(
                text: text, fontSize: font.body, highlights: chapterHighlights,
                header: AnyView(chapterHeader), headerKey: "\(chapter.slug)|\(view.apiValue)|\(chapterMeta)",
                chromeInsets: chromeInsets(proxy),
                sideInset: 24,
                initialCharIndex: restoreCharIndex,
                onTopChar: { c in pos.fullChar = c; schedulePositionSave() },
                onChromeVisible: followChrome,
                onCreate: { range, quote in editor = .new(range, quote) },
                onTapHighlight: { h in editor = .edit(h) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .vertical)
        }
    }

    // Summary: the same highlightable surface as the full text. It used to be
    // stacked Text views — readable and selectable, but not markable — on the
    // grounds that "highlights live on the full text". Nothing required that;
    // what was missing was a way to say which of a chapter's two texts an
    // offset belonged to.
    private var summaryContent: some View {
        GeometryReader { proxy in
            HighlightableText(
                text: text, fontSize: font.body, highlights: chapterHighlights,
                header: AnyView(chapterHeader), headerKey: "\(chapter.slug)|\(view.apiValue)|\(chapterMeta)",
                chromeInsets: chromeInsets(proxy),
                sideInset: 24,
                initialCharIndex: restoreCharIndex,
                onTopChar: { c in pos.summaryPara = paragraphIndex(forChar: c); schedulePositionSave() },
                onChromeVisible: followChrome,
                onCreate: { range, quote in editor = .new(range, quote) },
                onTapHighlight: { h in editor = .edit(h) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .vertical)
        }
    }

    private func chromeInsets(_ proxy: GeometryProxy) -> UIEdgeInsets {
        UIEdgeInsets(top: proxy.safeAreaInsets.top, left: 0, bottom: proxy.safeAreaInsets.bottom, right: 0)
    }

    // The summary's saved position is a paragraph index, on the server and in the
    // offline store both; the text view speaks character offsets. Rather than
    // migrate a format that works, translate at the boundary.

    /// UTF-16 offset where each rendered paragraph starts — the unit NSRange uses.
    /// `paragraphs` drops blank lines, so a paragraph's index is not its line's.
    private var paragraphStarts: [Int] {
        var starts: [Int] = []
        var offset = 0
        for line in text.components(separatedBy: "\n") {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { starts.append(offset) }
            offset += line.utf16.count + 1   // + the newline that split removed
        }
        return starts
    }

    private func charOffset(forParagraph index: Int) -> Int {
        let starts = paragraphStarts
        guard !starts.isEmpty, index > 0 else { return 0 }
        return starts[min(index, starts.count - 1)]
    }

    private func paragraphIndex(forChar char: Int) -> Int {
        let starts = paragraphStarts
        guard let i = starts.lastIndex(where: { $0 <= char }) else { return 0 }
        return i
    }

    private var paragraphs: [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Bottom panel (where you are · text or summary · chapter · note)

    private var bottomPanel: some View {
        VStack(spacing: 11) {
            VStack(spacing: 7) {
                HStack(spacing: 10) {
                    GridLabel("\(index + 1) / \(chapters.count) · \(chapter.title)", size: 9.5).lineLimit(1)
                    Spacer(minLength: 0)
                    GridLabel("\(Int((progress * 100).rounded())) %", size: 9.5)
                }
                GridBar(value: progress, accentWhenFull: false)
            }
            .padding(.horizontal, 6)

            HStack(spacing: 6) {
                ReaderModeSwitch(mode: $view, summaryEnabled: chapter.hasSummary)
                navButton(system: "chevron.left", enabled: index > 0) { go(-1) }
                navButton(system: "chevron.right", enabled: index < chapters.count - 1) { go(1) }
                // Write, or talk it over. The note goes on the member's side
                // of the book's entry, with this chapter's name; Maurice opens
                // on this chapter, with the fiche and the book up to here.
                panelIcon(label: "Note") {
                    Image(systemName: "pencil").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(CarnetTheme.accentInk)
                        .frame(width: 44, height: 36)
                        .background(Capsule().fill(CarnetTheme.accent))
                } action: { takingNote = true }
                if MauriceApp.installed {
                    panelIcon(label: "Talk about this chapter with Maurice") {
                        MauriceMark(size: 36)
                    } action: { talkToMaurice() }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func panelIcon<Label: View>(label: String, @ViewBuilder _ icon: () -> Label,
                                        action: @escaping () -> Void) -> some View {
        Button(action: action) { icon().contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .disabled(openingMaurice)
            .accessibilityLabel(label)
    }

    private func navButton(system: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 15, weight: .medium))
                .foregroundStyle(enabled ? CarnetTheme.ink : CarnetTheme.inkHint)
                .frame(width: 32, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(system == "chevron.left" ? "Previous chapter" : "Next chapter")
    }

    // MARK: - Note sheet

    private var noteSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            GridLabel("Note · \(chapter.title)")
            TextEditor(text: $note)
                .font(CarnetTheme.sans(15))
                .frame(minHeight: 120)
                .carnetField()
            HStack {
                Spacer()
                GridButton(title: "Cancel", small: true) { showNote = false }
                GridButton(title: "Save", primary: true, small: true) { saveNote() }
            }
        }
        .padding(20)
        .presentationDetents([.height(280)])
        .glassSheetBackground()
    }

    // MARK: - Actions


    private func go(_ delta: Int) {
        let next = index + delta
        guard chapters.indices.contains(next) else { return }
        flushPositionSave()   // save this chapter's position before moving on
        index = next
        if !chapters[next].hasSummary { view = .full }
    }

    private struct TaskKey: Equatable { let index: Int; let mode: ReaderMode }

    private func loadChapter() async {
        loading = true; error = nil
        // Seed the live positions from the saved record for THIS chapter (both
        // views), and arm the full-text restore BEFORE the text appears — the
        // text view applies it on its first layout of the new chapter.
        let rec = ReadingPositionStore.get(bookId: book.id)
        let sameChapter = rec?.chapterSlug == chapter.slug
        pos.fullChar = sameChapter ? (rec?.fullChar ?? 0) : 0
        pos.summaryPara = sameChapter ? (rec?.summaryPara ?? 0) : 0
        restoreCharIndex = view == .full ? pos.fullChar : charOffset(forParagraph: pos.summaryPara)
        // Preview / offline path.
        #if DEBUG
        if ReadingPreview.active {
            text = view == .summary ? Chapter.sampleSummary : Chapter.sampleText
            highlights = Chapter.sampleHighlights
            loading = false
            return
        }
        #endif
        if previewText != nil || previewSummary != nil {
            text = (view == .summary ? previewSummary : previewText) ?? previewText ?? ""
            highlights = previewHighlights ?? []
            loading = false
            return
        }
        // Get the chapter text: offline cache first, then network. Highlights and
        // bookmark are secondary — they must NOT gate the spinner, since the first
        // call to those endpoints can stall and the text is what the reader needs.
        let cachedText = view == .summary
            ? BookCache.chapterSummary(bookId: book.id, slug: chapter.slug)
            : BookCache.chapterText(bookId: book.id, slug: chapter.slug)
        if let cachedText {
            text = cachedText
        } else {
            do {
                if view == .summary {
                    let s = try await CalibreAPI.chapterSummary(bookId: book.id, slug: chapter.slug)
                    text = s.summary ?? ""
                    if !s.exists { error = "No summary for this chapter yet." }
                    else if let sum = s.summary { BookCache.cacheChapterSummary(bookId: book.id, slug: chapter.slug, text: sum) }
                } else {
                    let full = try await CalibreAPI.chapter(bookId: book.id, slug: chapter.slug).text
                    text = full
                    BookCache.cacheChapterText(bookId: book.id, slug: chapter.slug, text: full)
                }
            } catch {
                self.error = "Couldn't load this chapter.\n\(error.localizedDescription)"
                loading = false
                return
            }
        }
        loading = false   // text is ready — show it now, don't wait on the calls below
        persistPosition()  // record the visit at the restored position

        // Secondary, non-gating: highlights + bookmark. Cancellation-safe (try?),
        // so switching chapters mid-flight just abandons them.
        highlights = (try? await CalibreAPI.highlights(bookId: book.id)) ?? []
        await refreshBookmark()
    }

    /// Record the exact current position — locally (offline-first) and on the
    /// per-member server endpoint (syncs across a member's devices, last-write-
    /// wins). Both views' positions are kept; the active one syncs to the server.
    private func persistPosition() {
        guard previewText == nil, previewSummary == nil else { return }
        // Paused: the reader is consulting ahead on purpose and the marker is
        // held. Checked on device, not just server-side, because this write
        // happens offline too — and because the position the detail view
        // resumes from is the local one.
        guard !ReadingPositionStore.isPaused(bookId: book.id) else { return }
        let rec = ReadingPositionStore.Record(
            chapterIndex: chapter.index, chapterSlug: chapter.slug,
            lastView: view.apiValue, fullChar: pos.fullChar, summaryPara: pos.summaryPara,
            updatedAt: Date())
        ReadingPositionStore.save(bookId: book.id, rec)
        let serverPos = Double(view == .full ? pos.fullChar : pos.summaryPara)
        let id = book.id, idx = chapter.index, slug = chapter.slug, mode = view.apiValue
        Task { try? await CalibreAPI.setReadingProgress(bookId: id, chapterIndex: idx, chapterSlug: slug, view: mode, position: serverPos) }
    }

    /// Debounce scroll-driven saves — one write a second, not one per pixel.
    private func schedulePositionSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            persistPosition()
        }
    }

    private func flushPositionSave() {
        saveTask?.cancel()
        persistPosition()
    }

    private func refreshBookmark() async {
        guard let marks = try? await CalibreAPI.bookmarks(bookId: book.id) else { return }
        let mark = marks.first { $0.chapterSlug == chapter.slug && $0.view == view.apiValue }
        bookmarkId = mark?.id
        note = mark?.note ?? ""
    }

    private func toggleBookmark() {
        guard previewText == nil, previewSummary == nil else {
            bookmarkId = isBookmarked ? nil : -1
            if isBookmarked { showNote = true }
            return
        }
        let slug = chapter.slug, mode = view.apiValue, id = book.id
        Task {
            if let resp = try? await CalibreAPI.toggleBookmark(bookId: id, chapterSlug: slug, view: mode) {
                await MainActor.run {
                    bookmarkId = resp.bookmarked ? resp.bookmark?.id : nil
                    if resp.bookmarked { showNote = true }   // offer to annotate
                }
            }
        }
    }

    private func saveNote() {
        showNote = false
        guard let id = bookmarkId, previewText == nil else { return }
        let bookId = book.id, text = note
        Task { try? await CalibreAPI.updateBookmarkNote(bookId: bookId, bookmarkId: id, note: text.isEmpty ? nil : text) }
    }

    // MARK: - Highlights

    /// `talk`: the passage is talked over with Maurice as soon as it is saved.
    private func createHighlight(range: NSRange, quote: String, color: String, note: String, talk: Bool = false) {
        guard previewText == nil else { return }
        // The offsets are relative to whichever text is on screen, so the view
        // has to travel with them.
        let id = book.id, slug = chapter.slug, mode = view
        if talk { openingMaurice = true }
        Task {
            if let h = try? await CalibreAPI.createHighlight(
                bookId: id, chapterSlug: slug, quote: quote, color: color,
                note: note.isEmpty ? nil : note,
                startOffset: range.location, endOffset: range.location + range.length,
                view: mode.apiValue) {
                await MainActor.run {
                    highlights.append(h)
                    if talk { talkToMaurice(highlight: h.id) }
                }
            } else if talk {
                await MainActor.run {
                    openingMaurice = false
                    mauriceFailure = "The highlight could not be saved."
                }
            }
        }
    }

    // MARK: - Maurice

    /// A conversation in the Maurice app, held from this book: on the passage
    /// just highlighted, or on the chapter open here. What it comes to is
    /// written on the book's fiche once it settles, and shown with the passage.
    private func talkToMaurice(highlight: Int? = nil) {
        guard previewText == nil else { return }
        let id = book.id, slug = chapter.slug
        openingMaurice = true
        Task {
            do {
                let convo = try await MauriceAPI.open(book: id, chapter: slug, highlight: highlight)
                await MainActor.run {
                    openingMaurice = false
                    if let highlight, let i = highlights.firstIndex(where: { $0.id == highlight }) {
                        highlights[i].conversationId = convo
                        highlights[i].conversation = HighlightConversation(id: convo, title: nil, summary: nil)
                    }
                    flushPositionSave()
                    MauriceApp.open(conversation: convo)
                }
            } catch {
                await MainActor.run {
                    openingMaurice = false
                    mauriceFailure = error.localizedDescription
                }
            }
        }
    }

    private func updateHighlight(_ h: Highlight, color: String, note: String) {
        guard previewText == nil else { return }
        let id = book.id
        Task {
            if let updated = try? await CalibreAPI.updateHighlight(
                bookId: id, highlightId: h.id, note: note.isEmpty ? nil : note, color: color) {
                await MainActor.run {
                    // An update never touches the conversation, and answers
                    // without its summary: keep the one listed.
                    if let i = highlights.firstIndex(where: { $0.id == h.id }) {
                        var kept = updated
                        kept.conversationId = highlights[i].conversationId
                        kept.conversation = highlights[i].conversation
                        highlights[i] = kept
                    }
                }
            }
        }
    }

    private func deleteHighlight(_ h: Highlight) {
        guard previewText == nil else { return }
        let id = book.id
        Task {
            try? await CalibreAPI.deleteHighlight(bookId: id, highlightId: h.id)
            await MainActor.run { highlights.removeAll { $0.id == h.id } }
        }
    }
}

// MARK: - Reader mode + font size

enum ReaderMode: Equatable {
    case full, summary
    var apiValue: String { self == .summary ? "summary" : "full" }
}

enum ReaderFontSize: Int, CaseIterable {
    case small = 0, medium = 1, large = 2
    var body: CGFloat {
        switch self {
        case .small: return 15
        case .medium: return 17
        case .large: return 19.5
        }
    }
    var next: ReaderFontSize { ReaderFontSize(rawValue: (rawValue + 1) % ReaderFontSize.allCases.count) ?? .medium }
}
