import SwiftUI

/// Book-level highlights list — the payoff: every quoted passage with its note
/// and chapter reference; tap to jump back into the reader. Port of the design's
/// Highlights screen.
struct HighlightsView: View {
    let book: Book
    let chapters: [Chapter]
    var previewHighlights: [Highlight]? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var highlights: [Highlight] = []
    @State private var loading = true
    @State private var error: String?
    @State private var reading: ReaderTarget?

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
        // Open the reader as a cover, not a BookRoute push — HighlightsView is
        // itself a BookRoute destination, so pushing BookRoute from here would be
        // a recursive destination declaration and crash.
        .fullScreenCover(item: $reading) { t in
            NavigationStack { ReaderView(book: t.book, chapters: t.chapters, startIndex: t.index, mode: .full) }
        }
    }

    struct ReaderTarget: Identifiable {
        let book: Book
        let chapters: [Chapter]
        let index: Int
        var id: Int { index }
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
                        Button {
                            reading = ReaderTarget(book: book, chapters: chapters, index: chapterIndex(for: h))
                        } label: {
                            HighlightRow(highlight: h, chapterTitle: chapterTitle(for: h))
                        }
                        .buttonStyle(.plain)
                        GridRule()
                    }
                }
            }
        }
    }

    private func chapterIndex(for h: Highlight) -> Int {
        chapters.firstIndex { $0.slug == h.chapterSlug } ?? 0
    }
    private func chapterTitle(for h: Highlight) -> String {
        chapters.first { $0.slug == h.chapterSlug }?.title ?? h.chapterSlug
    }

    private func load() async {
        if let previewHighlights { highlights = previewHighlights; loading = false; return }
        #if DEBUG
        if ReadingPreview.active { highlights = Chapter.sampleHighlights; loading = false; return }
        #endif
        loading = highlights.isEmpty
        error = nil
        do {
            highlights = try await CalibreAPI.highlights(bookId: book.id)
        } catch {
            self.error = "Couldn't load highlights.\n\(error.localizedDescription)"
        }
        loading = false
    }
}

// MARK: - Row

private struct HighlightRow: View {
    let highlight: Highlight
    let chapterTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Quote with a coloured edge
            Text(highlight.quote)
                .font(CarnetTheme.sans(14.5))
                .foregroundStyle(CarnetTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 11)
                .overlay(alignment: .leading) {
                    Rectangle().fill(HighlightPalette.color(highlight.color)).frame(width: 3)
                }

            if let note = highlight.note, !note.isEmpty {
                Text("✎ \(note)")
                    .font(CarnetTheme.sans(13))
                    .foregroundStyle(CarnetTheme.inkSoft)
                    .padding(.leading, 11)
            }

            GridLabel("\(chapterTitle) · tap to jump back", size: 9)
                .padding(.leading, 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}
