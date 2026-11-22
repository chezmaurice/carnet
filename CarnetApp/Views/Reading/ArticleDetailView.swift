import SwiftUI

/// One saved article — status, resume, summary, highlights, comment, and the
/// outbound links. The article twin of BookDetailView.
struct ArticleDetailView: View {
    let article: Article

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Live copy — refreshed on load so a summary generated elsewhere shows up.
    @State private var current: Article
    @State private var body_: String = ""
    @State private var highlightCount: Int
    @State private var summarizing = false
    @State private var summaryError: String?
    @State private var reading = false
    @State private var showHighlights = false
    @State private var showResonance = false
    @State private var showNote = false

    init(article: Article) {
        self.article = article
        self._current = State(initialValue: article)
        self._highlightCount = State(initialValue: article.highlightCount ?? 0)
    }

    /// Readable on this device right now (server captured it, or a copy is cached).
    private var readableNow: Bool { current.readable || ArticleCache.hasText(current) }
    private var cachedOnDevice: Bool { ArticleCache.hasText(current) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                statusCard
                if readableNow { readCard }
                summaryCard
                highlightsButton
                resonanceButton
                commentCard
                linksCard
            }
            .padding(.bottom, 24)
        }
        .background(CarnetTheme.bg)
        .gridTopChrome { GridChromeRow { GridBackButton { dismiss() } } }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .fullScreenCover(isPresented: $reading) {
            NavigationStack { ArticleReaderView(article: current) }
        }
        .fullScreenCover(isPresented: $showHighlights) {
            NavigationStack { ArticleHighlightsView(article: current) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverImage(article: current, width: 78, height: 110)
            VStack(alignment: .leading, spacing: 0) {
                Text(current.title)
                    .font(CarnetTheme.display(22, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(CarnetTheme.ink)
                if let subtitle = current.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(CarnetTheme.sans(13))
                        .foregroundStyle(CarnetTheme.inkSoft)
                        .padding(.top, 4)
                }
                Text(current.bylineShort)
                    .font(CarnetTheme.sans(13))
                    .foregroundStyle(CarnetTheme.inkMute)
                    .padding(.top, 4)
                if let words = current.wordCount, words > 0 {
                    HStack(spacing: 20) {
                        stat("Words", "\(words)")
                        stat("Est.", "\(current.readingMinutes) min")
                    }
                    .padding(.top, 14)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            GridLabel(label, size: 9)
            Text(value).font(CarnetTheme.mono(13)).foregroundStyle(CarnetTheme.ink)
        }
    }

    // MARK: - Capture status — the "is it readable here?" indication

    @ViewBuilder private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if current.isBookmarkOnly && !cachedOnDevice {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark").font(.system(size: 13))
                    GridLabel("Text not captured — bookmark only", size: 10)
                }
                .foregroundStyle(CarnetTheme.inkSoft)
                Text("The page couldn't be read when it was saved. Open it in the browser, then save it again from there to fill it in.")
                    .font(CarnetTheme.sans(13))
                    .foregroundStyle(CarnetTheme.inkSoft)
                if let err = current.captureError, !err.isEmpty {
                    Text(err)
                        .font(CarnetTheme.mono(10.5))
                        .foregroundStyle(CarnetTheme.inkMute)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: cachedOnDevice ? "arrow.down.circle.fill" : "doc.text")
                        .font(.system(size: 13))
                    GridLabel(cachedOnDevice ? "Full text available · offline" : "Full text available",
                              size: 10)
                }
                .foregroundStyle(CarnetTheme.inkSoft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(CarnetTheme.surface)
        .overlay(Rectangle().strokeBorder(CarnetTheme.rule, lineWidth: 1))
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.bottom, 12)
    }

    // MARK: - Read

    private var readCard: some View {
        Button { reading = true } label: {
            HStack(spacing: 7) {
                Image(systemName: "book").font(.system(size: 15))
                Text("Read").font(CarnetTheme.sans(14, weight: .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .foregroundStyle(CarnetTheme.accentInk).background(CarnetTheme.accent)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.bottom, 12)
    }

    // MARK: - Summary

    @ViewBuilder private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            GridLabel("Summary")
            if let summary = current.summary, !summary.isEmpty {
                Text(summary)
                    .font(CarnetTheme.sans(14))
                    .foregroundStyle(CarnetTheme.ink)
                    .lineLimit(6)
            } else if current.isBookmarkOnly {
                Text("Nothing to summarize until the text is captured.")
                    .font(CarnetTheme.sans(13))
                    .foregroundStyle(CarnetTheme.inkMute)
            } else {
                Text("No summary yet.")
                    .font(CarnetTheme.sans(13))
                    .foregroundStyle(CarnetTheme.inkMute)
            }
            if summarizing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(CarnetTheme.inkMute)
                    GridLabel("Summarizing…", size: 9.5, color: CarnetTheme.inkSoft)
                }
            } else if !current.isBookmarkOnly {
                GridButton(title: current.hasSummary ? "Regenerate" : "Summarize",
                           systemImage: "sparkles", small: true) {
                    Task { await summarize(force: current.hasSummary) }
                }
            }
            if let summaryError {
                Text(summaryError)
                    .font(CarnetTheme.caption)
                    .foregroundStyle(CarnetTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(CarnetTheme.surface)
        .overlay(Rectangle().strokeBorder(CarnetTheme.rule, lineWidth: 1))
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.bottom, 12)
    }

    // MARK: - Highlights

    @ViewBuilder private var highlightsButton: some View {
        let has = highlightCount > 0
        Button { showHighlights = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "highlighter").font(.system(size: 14))
                Text("Highlights").font(CarnetTheme.sans(14, weight: .medium))
                Spacer()
                if has {
                    Text("\(highlightCount)").font(CarnetTheme.mono(12)).foregroundStyle(CarnetTheme.inkSoft)
                }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CarnetTheme.inkMute)
            }
            .foregroundStyle(has ? CarnetTheme.ink : CarnetTheme.inkMute)
            .padding(.horizontal, 16).padding(.vertical, 13)
            .overlay(Rectangle().strokeBorder(CarnetTheme.ruleHard, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!has)
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.bottom, 12)
    }

    // MARK: - Resonance ("this feeds my Sugar fiche")

    private var resonanceButton: some View {
        Button { showResonance = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "leaf").font(.system(size: 14))
                Text("Resonance").font(CarnetTheme.sans(14, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CarnetTheme.inkMute)
            }
            .foregroundStyle(CarnetTheme.ink)
            .padding(.horizontal, 16).padding(.vertical, 13)
            .overlay(Rectangle().strokeBorder(CarnetTheme.ruleHard, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.bottom, 12)
        // On the button, not the ScrollView: presentation modifiers stacked on
        // one view fight for the slot and the sheet never shows.
        .sheet(isPresented: $showResonance) {
            ResonanceSheet(sourceLabel: current.title,
                           sourceBasename: "\(current.slug)-fiche")
        }
    }

    // MARK: - Fiche (the body — why it was saved; or, unopened, why not yet)
    //
    // A bare share writes an unopened fiche: the file exists, nobody has
    // written on it. Writing a note is what opens it — so this card is both
    // the notes and the way in.

    private var commentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                GridLabel(current.isOpened ? "Fiche" : "Not a fiche yet")
                Spacer(minLength: 0)
                GridButton(title: current.isOpened ? "Add a note" : "Open the fiche",
                           systemImage: "pencil.line", small: true) { showNote = true }
            }
            if !body_.isEmpty {
                WikiText(text: body_)
                    .font(CarnetTheme.sans(14))
                    .foregroundStyle(CarnetTheme.ink)
            } else if !current.isOpened {
                Text("Saved without a word. Write one and it becomes a fiche in your notes — until then it only lives here, on the shelf.")
                    .font(CarnetTheme.sans(13))
                    .foregroundStyle(CarnetTheme.inkMute)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(CarnetTheme.surface)
        .overlay(Rectangle().strokeBorder(CarnetTheme.rule, lineWidth: 1))
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.bottom, 12)
        // On the card, not the ScrollView — see resonanceButton.
        .sheet(isPresented: $showNote) {
            ArticleNoteSheet(article: current) { detail in
                current = detail.article
                body_ = detail.body
            }
        }
    }

    // MARK: - Outbound links

    @ViewBuilder private var linksCard: some View {
        VStack(spacing: 0) {
            if let urlString = current.url, let url = URL(string: urlString) {
                linkRow("Open in browser", system: "safari") { openURL(url) }
                GridRule()
            }
            if let path = current.ficheWebPath {
                linkRow("Open in the browser", system: "leaf") {
                    Task { if let url = await GardenLinks.webURL(path) { openURL(url) } }
                }
            }
        }
        .overlay(Rectangle().strokeBorder(CarnetTheme.ruleHard, lineWidth: 1))
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
    }

    private func linkRow(_ title: String, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: system).font(.system(size: 14))
                Text(title).font(CarnetTheme.sans(14, weight: .medium))
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CarnetTheme.inkMute)
            }
            .foregroundStyle(CarnetTheme.ink)
            .padding(.horizontal, 16).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Loading / actions

    private func load() async {
        do {
            let detail = try await GardenAPI.article(slug: article.slug, locale: article.locale)
            current = detail.article
            body_ = detail.body
        } catch {
            // Offline or server unreachable — the list's copy is enough to render.
        }
        if let hs = try? await GardenAPI.highlights(slug: article.slug, locale: article.locale) {
            highlightCount = hs.count
        }
    }

    private func summarize(force: Bool) async {
        summarizing = true; summaryError = nil
        do {
            _ = try await GardenAPI.summarize(slug: article.slug, locale: article.locale, force: force)
            // Re-read the fiche so `summary` (and its stamp) reflect what was stored.
            if let detail = try? await GardenAPI.article(slug: article.slug, locale: article.locale) {
                current = detail.article
            }
        } catch {
            summaryError = "Couldn't summarize.\n\(error.localizedDescription)"
        }
        summarizing = false
    }
}

// MARK: - Note sheet

/// A dated note on the article's fiche — the same line a re-share with a
/// comment would add. On an unopened fiche this is the opening gesture.
struct ArticleNoteSheet: View {
    let article: Article
    var onDone: (ArticleDetail) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var sending = false
    @State private var error: String?

    private var trimmed: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GridLabel(article.isOpened ? "Note" : "Open the fiche")
            Text(article.title)
                .font(CarnetTheme.sans(14, weight: .semibold))
                .foregroundStyle(CarnetTheme.ink)
                .lineLimit(2)

            TextEditor(text: $note)
                .font(CarnetTheme.sans(15))
                .frame(minHeight: 110)
                .carnetField()

            if let error {
                Text(error).font(CarnetTheme.caption).foregroundStyle(CarnetTheme.inkSoft)
            }

            HStack {
                Spacer()
                GridButton(title: "Cancel", small: true) { dismiss() }
                GridButton(title: sending ? "Saving…" : "Save", primary: true, small: true) {
                    Task { await send() }
                }
                .disabled(sending || trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassSheetBackground()
        .presentationDetents([.height(360), .large])
    }

    private func send() async {
        sending = true; error = nil
        do {
            let detail = try await GardenAPI.addComment(slug: article.slug, locale: article.locale, comment: trimmed)
            onDone(detail)
            dismiss()
        } catch {
            self.error = "Couldn't save the note.\n\(error.localizedDescription)"
        }
        sending = false
    }
}

// MARK: - Article highlights list

/// Every highlighted passage of one article; tap to jump back into the reader.
struct ArticleHighlightsView: View {
    let article: Article

    @Environment(\.dismiss) private var dismiss
    @State private var highlights: [Highlight] = []
    @State private var loading = true
    @State private var error: String?
    @State private var reading = false

    var body: some View {
        VStack(spacing: 0) {
            GridTitle(title: "Highlights", kicker: loading ? nil : "\(highlights.count)")
            GridRule()
            content
        }
        .background(CarnetTheme.bg)
        .gridTopChrome { GridChromeRow { GridBackButton { dismiss() } } }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .fullScreenCover(isPresented: $reading) {
            NavigationStack { ArticleReaderView(article: article) }
        }
    }

    @ViewBuilder private var content: some View {
        if loading {
            GridLoading()
        } else if let error {
            GridMessage(text: error)
        } else if highlights.isEmpty {
            GridMessage(text: "No highlights yet.\nSelect text while reading to highlight it.",
                        systemImage: "highlighter")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(highlights) { h in
                        Button { reading = true } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(h.quote)
                                    .font(CarnetTheme.sans(14.5))
                                    .foregroundStyle(CarnetTheme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 11)
                                    .overlay(alignment: .leading) {
                                        Rectangle().fill(HighlightPalette.color(h.color)).frame(width: 3)
                                    }
                                if let note = h.note, !note.isEmpty {
                                    Text("✎ \(note)")
                                        .font(CarnetTheme.sans(13))
                                        .foregroundStyle(CarnetTheme.inkSoft)
                                        .padding(.leading, 11)
                                }
                                GridLabel(h.readerView == "summary" ? "In the summary · tap to jump back"
                                                                    : "Tap to jump back", size: 9)
                                    .padding(.leading, 11)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        GridRule()
                    }
                }
            }
        }
    }

    private func load() async {
        loading = highlights.isEmpty
        error = nil
        do {
            highlights = try await GardenAPI.highlights(slug: article.slug, locale: article.locale)
        } catch {
            self.error = "Couldn't load highlights.\n\(error.localizedDescription)"
        }
        loading = false
    }
}
