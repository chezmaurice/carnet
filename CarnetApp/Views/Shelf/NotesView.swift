import SwiftUI

/// Every note the member wrote, whatever the entry — newest first, by month.
///
/// The list finds a note through what it was written on. This is the other
/// way round: a note remembered for itself, roughly when or roughly what,
/// when the article it sits under is long forgotten. Each one names its entry
/// in small, and a tap opens it.
struct NotesView: View {
    var open: (ShelfEntry) -> Void
    var onBack: () -> Void

    @State private var notes: [FeedNote] = []
    @State private var entries: [String: ShelfEntry] = [:]
    @State private var loading = true
    @State private var error: String?
    @State private var searching = false
    @State private var query = ""
    /// A note opened to be rewritten, or to be taken off.
    @State private var editing: NoteEditTarget?
    @State private var deleting: NoteEditTarget?
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                GridTitle(title: "Notes", kicker: loading ? "What you wrote" : "What you wrote · \(visible.count)")
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
        .gridTopChrome {
            GridChromeRow {
                GridBackButton(size: 40, action: onBack)
            } trailing: {
                GridIconButton(systemName: "magnifyingglass", primary: searching, size: 40) {
                    withAnimation(.easeOut(duration: 0.18)) { searching.toggle() }
                    searchFocused = searching
                    if !searching { query = "" }
                }
                .accessibilityLabel("Search")
            }
        }
        .background(CarnetTheme.bg)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // Coming back from an entry: a note may have been added there.
        .onAppear { Task { await fetch() } }
        .noteEditing($editing, deleting: $deleting) { await fetch() }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(CarnetTheme.inkMute)
            TextField("A word of the note, or of its entry", text: $query)
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

    /// Every word typed must be somewhere in the note or on its entry's line,
    /// accents and case aside.
    private var visible: [FeedNote] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return notes }
        return notes.filter { note in
            let entry = entries[note.entryId]
            let hay = [note.item.text, note.item.quote, note.item.from?.label, entry?.title, entry?.byline]
                .compactMap { $0 }.joined(separator: "\n")
            return words.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// The notes by month, in the order they came; what carries no date last.
    private var months: [(key: String, notes: [FeedNote])] {
        var out: [(key: String, notes: [FeedNote])] = []
        for note in visible {
            let key = String((note.item.date ?? "").prefix(7))
            if out.last?.key == key { out[out.count - 1].notes.append(note) }
            else { out.append((key, [note])) }
        }
        return out
    }

    private static let monthIn: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()
    private static let monthOut: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    private func monthLabel(_ key: String) -> String {
        guard let date = Self.monthIn.date(from: key) else { return "Undated" }
        return Self.monthOut.string(from: date)
    }

    private var list: some View {
        VStack(spacing: 0) {
            if visible.isEmpty {
                GridRule()
                Text(notes.isEmpty ? "Nothing here yet. A note you write on an entry is kept here too."
                                   : "Nothing matches.")
                    .font(CarnetTheme.caption)
                    .foregroundStyle(CarnetTheme.inkHint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                    .padding(.vertical, 40)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(months, id: \.key) { month in
                        GridLabel(monthLabel(month.key), size: 9.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                            .padding(.top, 18)
                            .padding(.bottom, 8)
                        GridRule()
                        ForEach(month.notes) { note in
                            if let entry = entries[note.entryId], note.item.canEdit || note.item.canDelete {
                                // The note opens to be rewritten; its entry's line, the entry.
                                NoteRow(note: note, entry: entry,
                                        onEdit: { editing = NoteEditTarget(entry: entry, item: note.item) },
                                        onDelete: { deleting = NoteEditTarget(entry: entry, item: note.item) },
                                        onOpen: { open(entry) })
                            } else {
                                Button {
                                    if let entry = entries[note.entryId] { open(entry) }
                                } label: {
                                    NoteRow(note: note, entry: entries[note.entryId])
                                }
                                .buttonStyle(.plain)
                                .disabled(entries[note.entryId] == nil)
                            }
                            GridRule()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Loading

    private func fetch() async {
        do {
            let response = try await GardenAPI.notes()
            entries = Dictionary(response.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            notes = response.notes
            error = nil
            loading = false
        } catch {
            if error.isCancellation { return }
            if notes.isEmpty { self.error = "Couldn't load your notes.\n\(error.localizedDescription)" }
            loading = false
        }
    }
}

/// One note as its entry's page shows it, and under it, in small, the entry.
private struct NoteRow: View {
    let note: FeedNote
    let entry: ShelfEntry?
    /// Set when the note may be rewritten or taken off: the note and its
    /// entry's line are then two targets instead of one.
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let onEdit, let onDelete {
                MineItemView(item: note.item).noteActions(note.item, onEdit: onEdit, onDelete: onDelete)
            } else {
                MineItemView(item: note.item)
            }
            if let entry {
                if let onOpen {
                    entryLine(entry)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onOpen)
                        .accessibilityAddTraits(.isButton)
                } else {
                    entryLine(entry)
                }
            }
        }
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func entryLine(_ entry: ShelfEntry) -> some View {
        HStack(spacing: 8) {
            CoverImage(shelf: entry, width: 16, height: entry.kind.squareCover ? 16 : 22)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            Text(entry.title)
                .font(CarnetTheme.sans(12.5, weight: .medium))
                .foregroundStyle(CarnetTheme.inkSoft)
                .lineLimit(1)
            GridLabel(entry.kind.singular, size: 9)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(CarnetTheme.inkHint)
        }
    }
}
