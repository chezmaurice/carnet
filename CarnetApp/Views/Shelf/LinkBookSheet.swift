import SwiftUI

// Tying a book entry to a book of the household's library, by hand: what the
// title alone could not settle — another edition, a subtitle, an author the
// library does not know — or settled wrongly. The fiche carries the book's id
// from then on, and the entry reads, highlights and resumes from that book.

struct LinkBookSheet: View {
    let entry: ShelfEntry
    /// The entry as the server answers it once tied.
    let onLinked: (GardenAPI.Written) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var books: [Book] = []
    @State private var query: String
    @State private var loading = true
    @State private var loadError: String?
    @State private var linking: Int?
    @State private var linkError: String?
    @FocusState private var focused: Bool

    init(entry: ShelfEntry, onLinked: @escaping (GardenAPI.Written) -> Void) {
        self.entry = entry
        self.onLinked = onLinked
        // The title without its subtitle: the library often has one without the other.
        let main = entry.title.components(separatedBy: CharacterSet(charactersIn: ":—–(")).first ?? entry.title
        _query = State(initialValue: main.trimmingCharacters(in: .whitespaces))
    }

    private var current: Int? { entry.source?.isBook == true ? entry.source?.bookId : nil }

    /// Every word typed, in the title or the authors, accents and case aside.
    private var found: [Book] {
        let words = Self.fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return books }
        return books.filter { book in
            let hay = Self.fold(book.title + " " + book.authors.joined(separator: " "))
            return words.allSatisfy { hay.contains($0) }
        }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "œ", with: "oe")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("link_book.hint"))
                        .font(CarnetTheme.sans(13.5)).foregroundStyle(CarnetTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(L("link_book.search"), text: $query)
                        .font(CarnetTheme.sans(15))
                        .focused($focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .padding(12)
                        .paper(.mine, in: RoundedRectangle(cornerRadius: CarnetTheme.cardCornerRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: CarnetTheme.cardCornerRadius, style: .continuous)
                            .strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
                    if let linkError {
                        Text(linkError).font(CarnetTheme.sans(13)).foregroundStyle(CarnetTheme.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    results
                }
                .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(CarnetTheme.bg)
            .navigationTitle(L(current == nil ? "link_book.title" : "link_book.title_change"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.close")) { dismiss() }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private var results: some View {
        if loading {
            ProgressView().tint(CarnetTheme.inkMute).frame(maxWidth: .infinity).padding(.top, 20)
        } else if let loadError {
            note(loadError)
        } else if found.isEmpty {
            note(L(books.isEmpty ? "link_book.empty_library" : "link_book.none"))
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(found.prefix(60)) { book in
                    row(book)
                    Divider().overlay(CarnetTheme.rule)
                }
            }
        }
    }

    private func row(_ book: Book) -> some View {
        Button { Task { await link(book) } } label: {
            HStack(spacing: 12) {
                CoverImage(bookId: book.id, letter: book.coverLetter, width: 34, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(CarnetTheme.sans(14.5, weight: .medium)).foregroundStyle(CarnetTheme.ink)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Text(book.author)
                        .font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkMute).lineLimit(1)
                }
                Spacer(minLength: 0)
                if linking == book.id {
                    ProgressView().tint(CarnetTheme.inkMute)
                } else if book.id == current {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CarnetTheme.ink)
                        .accessibilityLabel(L("link_book.current"))
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(linking != nil || book.id == current)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(CarnetTheme.sans(13.5)).foregroundStyle(CarnetTheme.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }

    private func load() async {
        do {
            books = try await CalibreAPI.books().sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        } catch {
            if !error.isCancellation { loadError = L("link_book.offline") }
        }
        loading = false
    }

    private func link(_ book: Book) async {
        linking = book.id
        linkError = nil
        do {
            onLinked(try await GardenAPI.linkBook(entry, bookId: book.id))
            dismiss()
        } catch {
            linkError = EntryView.message(error)
        }
        linking = nil
    }
}
