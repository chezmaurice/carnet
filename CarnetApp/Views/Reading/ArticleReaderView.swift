import SwiftUI

/// Article reader — the same reading surface as a book chapter (full text ⇄
/// summary, adjustable type, passage highlights, exact position restore), for
/// an article's single text. Deliberately its own thin view rather than a
/// generalisation of ReaderView: the article has no chapter nav, no server
/// reading-progress sync and no chapter bookmarks, and the shared machinery
/// (HighlightableText, the editor sheet, fonts) is already componentised.
struct ArticleReaderView: View {
    let article: Article
    var startMode: ReaderMode = .full

    @Environment(\.dismiss) private var dismiss
    @AppStorage("carnet.reader.fontSize") private var fontRaw = ReaderFontSize.medium.rawValue

    @State private var view: ReaderMode
    @State private var text: String = ""
    @State private var styles: [TextStyle] = []
    @State private var loading = true
    @State private var error: String?
    @State private var highlights: [Highlight] = []
    @State private var editor: HLEditor?
    @State private var showNote = false
    /// The article's entry, read beside the text: what Maurice is asked from.
    @State private var entry: ShelfEntry?
    @State private var asking = false
    /// A conversation with Maurice being opened on a passage, and why it could not.
    @State private var openingMaurice = false
    @State private var mauriceFailure: String?

    @State private var restoreCharIndex: Int = 0
    @State private var pos = PositionBox()
    @State private var saveTask: Task<Void, Never>?
    /// The bars step aside while the reader reads on (see ReaderView).
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

    init(article: Article, startMode: ReaderMode = .full, entry: ShelfEntry? = nil) {
        self.article = article
        self.startMode = startMode
        self._entry = State(initialValue: entry)
        self._view = State(initialValue: startMode == .summary && article.hasSummary ? .summary : .full)
    }

    private var font: ReaderFontSize { ReaderFontSize(rawValue: fontRaw) ?? .medium }
    private var positionKey: String { "article:\(article.id)" }
    private var viewHighlights: [Highlight] {
        highlights.filter { $0.readerView == view.apiValue }
    }

    var body: some View {
        // The text runs the whole height of the screen and scrolls beneath
        // the chrome: three controls floating at the top, and at the bottom
        // the writing panel on its own glass, as on the entry's page — bare
        // over the text, the note field floated a little too much.
        content
            .gridTopChrome { topBar.readerChrome(hidden: chromeHidden, edge: .top) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomPanel.glassFooter().readerChrome(hidden: chromeHidden, edge: .bottom)
            }
            .background(CarnetTheme.bg)
            .onChange(of: view) { _, _ in withAnimation(.easeOut(duration: 0.22)) { chromeHidden = false } }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: view) { await load() }
        .onDisappear { flushPositionSave() }
        .sheet(item: $editor) { ed in editorSheet(ed) }
        // The entry page's own note sheet — the same fields, the same
        // dictation — writing to the same place.
        .sheet(isPresented: $showNote) {
            NoteSheet(title: article.title, locale: Locale(identifier: article.locale)) { text, quote, page in
                _ = try await GardenAPI.addNote(to: try await resolveEntry(), text: text, quote: quote, page: page)
            }
        }
        // In the Maurice app, with the article in context — or, without it, in
        // Carnet's own thread.
        .mauriceHandoff(entry: entry, trigger: $asking)
        .overlay { if openingMaurice { ProgressView().tint(CarnetTheme.inkMute) } }
        .alert("Maurice could not be opened",
               isPresented: Binding(get: { mauriceFailure != nil }, set: { if !$0 { mauriceFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(mauriceFailure ?? "")
        }
    }

    /// A passage is talked over from the member's own article; one given from
    /// another household is read in its owner's notes.
    private var talks: Bool { article.owner == nil }

    @ViewBuilder private func editorSheet(_ ed: HLEditor) -> some View {
        switch ed {
        case let .new(range, quote):
            HighlightEditorSheet(quote: quote, color: "yellow", note: "", isEditing: false,
                resonance: ResonanceSource(label: article.title, basename: "\(article.slug)-fiche"),
                onSave: { color, note in createHighlight(range: range, quote: quote, color: color, note: note) },
                onTalk: talks ? { color, note in createHighlight(range: range, quote: quote, color: color, note: note, talk: true) } : nil)
        case let .edit(h):
            HighlightEditorSheet(quote: h.quote, color: h.color, note: h.note ?? "", isEditing: true,
                onSave: { color, note in updateHighlight(h, color: color, note: note) },
                onDelete: { deleteHighlight(h) },
                conversation: h.conversation,
                onTalk: talks ? { color, note in
                    if color != h.color || note != (h.note ?? "") { updateHighlight(h, color: color, note: note) }
                    talkToMaurice(highlight: h.id)
                } : nil)
        }
    }

    // MARK: - Top bar

    // Back at the leading edge, type size at the trailing edge, and between
    // them, centred, which text is read: the article or its summary. The two
    // sides are the same width, which is what keeps the switch in the middle.
    private var topBar: some View {
        HStack(spacing: 12) {
            GlassBar { GridBackButton(size: 40) { flushPositionSave(); dismiss() } }
            Spacer(minLength: 0)
            GlassBar { ReaderModeSwitch(mode: $view, summaryEnabled: article.hasSummary) }
                .frame(maxWidth: 230)
            Spacer(minLength: 0)
            GlassBar { ReaderFontButton(raw: $fontRaw) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    // MARK: - Bottom panel (writing)

    // The same panel as the entry's page: a note, or Maurice. A note lands
    // on the article's fiche, the line a re-share with a comment would add.
    private var bottomPanel: some View {
        WritePanel(onNote: { showNote = true }, onAsk: entry == nil ? nil : { asking = true })
    }

    /// The article's entry: the one read beside the text, or read now when a
    /// note is kept before it arrived.
    private func resolveEntry() async throws -> ShelfEntry {
        if let entry { return entry }
        let found = try await GardenAPI.entryPage(collection: "articles", locale: article.locale, slug: article.slug).entry
        entry = found
        return found
    }

    // MARK: - Content

    private var content: some View {
        Group {
            if loading {
                GridLoading()
            } else if let error {
                GridMessage(text: error)
            } else {
                // The heading is the first thing in the text's own flow, not a
                // band pinned above it: three lines of title held on screen
                // for the whole reading cost a fifth of the page.
                // The bars' heights, read here and handed to the text, which
                // then runs the whole screen beneath them.
                GeometryReader { proxy in
                    HighlightableText(
                        text: text, fontSize: font.body, highlights: viewHighlights,
                        styles: styles,
                        header: AnyView(header), headerKey: "\(article.id)|\(headerMeta)",
                        chromeInsets: UIEdgeInsets(top: proxy.safeAreaInsets.top, left: 0,
                                                   bottom: proxy.safeAreaInsets.bottom, right: 0),
                        sideInset: 24,
                        initialCharIndex: restoreCharIndex,
                        onTopChar: { c in
                            if view == .full { pos.fullChar = c } else { pos.summaryPara = c }
                            schedulePositionSave()
                        },
                        onChromeVisible: { visible in
                            withAnimation(.easeOut(duration: 0.22)) { chromeHidden = !visible }
                        },
                        onCreate: { range, quote in if article.owner == nil { editor = .new(range, quote) } },
                        onTapHighlight: { h in editor = .edit(h) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .vertical)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReaderHeading(eyebrow: article.bylineShort.isEmpty ? "Article" : article.bylineShort,
                          title: article.title, meta: headerMeta, titleLines: 8, inset: 0)
            GridRule()
        }
        .padding(.bottom, 16)
    }

    private var headerMeta: String {
        let n = viewHighlights.count
        let marks = n == 0 ? "" : " · \(n) highlight\(n == 1 ? "" : "s")"
        return "\(article.readingMinutes) min\(marks)"
    }

    // MARK: - Loading

    private func load() async {
        loading = true; error = nil
        // Arm the restore before the text appears; the text view applies it on
        // its first layout. Positions here are character offsets in both views —
        // the paragraph-index translation books do exists only for their
        // server-side progress sync, which articles don't have.
        let rec = ReadingPositionStore.get(key: positionKey)
        pos.fullChar = rec?.fullChar ?? 0
        pos.summaryPara = rec?.summaryPara ?? 0
        restoreCharIndex = view == .full ? pos.fullChar : pos.summaryPara

        if view == .summary {
            text = article.readableSummary
            styles = []
            if text.isEmpty { error = "No summary for this article yet." }
        } else if let cached = ArticleCache.text(article) {
            text = cached
            styles = ArticleCache.styles(article)
        } else {
            do {
                let full = try await GardenAPI.articleText(slug: article.slug, locale: article.locale, owner: article.owner)
                text = full.text
                styles = full.styles ?? []
                ArticleCache.cacheText(article, text: full.text, styles: styles)
            } catch {
                if error.isCancellation { return }
                self.error = "Couldn't load this article.\n\(error.localizedDescription)"
                loading = false
                return
            }
        }
        loading = false
        persistPosition()

        // Secondary, non-gating — the text is what the reader needs first.
        _ = try? await resolveEntry()
        // Highlights are kept against the member's own fiche: an article
        // read in someone else's notes has none to show or keep.
        guard article.owner == nil else { return }
        highlights = (try? await GardenAPI.highlights(slug: article.slug, locale: article.locale)) ?? []
    }

    // MARK: - Position (local only — no server sync for articles)

    private func persistPosition() {
        let rec = ReadingPositionStore.Record(
            chapterIndex: 0, chapterSlug: article.slug,
            lastView: view.apiValue, fullChar: pos.fullChar, summaryPara: pos.summaryPara,
            updatedAt: Date())
        ReadingPositionStore.save(key: positionKey, rec)
    }

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

    // MARK: - Highlights

    /// `talk`: the passage is talked over with Maurice as soon as it is saved.
    private func createHighlight(range: NSRange, quote: String, color: String, note: String, talk: Bool = false) {
        let slug = article.slug, locale = article.locale, mode = view
        if talk { openingMaurice = true }
        Task {
            if let h = try? await GardenAPI.createHighlight(
                slug: slug, locale: locale, quote: quote, color: color,
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

    /// A conversation in the Maurice app, held from this article, on the
    /// passage just highlighted. What it comes to is written on the
    /// article's fiche once it settles, and shown with the passage.
    private func talkToMaurice(highlight: Int) {
        let ref = "articles/\(article.locale)/\(article.slug)"
        openingMaurice = true
        Task {
            do {
                let convo = try await MauriceAPI.open(from: ref, articleHighlight: highlight)
                await MainActor.run {
                    openingMaurice = false
                    if let i = highlights.firstIndex(where: { $0.id == highlight }) {
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
        let slug = article.slug
        Task {
            if let updated = try? await GardenAPI.updateHighlight(
                slug: slug, highlightId: h.id, note: note.isEmpty ? nil : note, color: color) {
                await MainActor.run {
                    // An update answers without the conversation's summary:
                    // keep the one listed.
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
        let slug = article.slug
        Task {
            try? await GardenAPI.deleteHighlight(slug: slug, highlightId: h.id)
            await MainActor.run { highlights.removeAll { $0.id == h.id } }
        }
    }
}
