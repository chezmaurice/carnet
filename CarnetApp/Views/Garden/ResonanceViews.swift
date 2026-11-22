import SwiftUI

// MARK: - Wiki-linked text
//
// Renders markdown-ish body text with [[wiki-links]] tappable: [[sugar-fiche]]
// or [[sugar|Sugar]] shows its label and opens the garden entry in a sheet.

struct WikiText: View {
    let text: String

    @State private var opened: GardenEntry?
    @State private var username = ""
    @State private var resolving = false

    private static let wikiRE = try! NSRegularExpression(pattern: #"\[\[([^\]|]+?)(?:\|([^\]]+?))?\]\]"#)

    var body: some View {
        Text(attributed)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "carnet-wiki", let host = url.host() else { return .systemAction }
                Task { await open(basename: host) }
                return .handled
            })
            .sheet(item: $opened) { entry in
                NavigationStack { GardenEntryView(entry: entry, username: username) }
            }
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        let ns = text as NSString
        var last = 0
        for m in Self.wikiRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                out += AttributedString(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            }
            let target = ns.substring(with: m.range(at: 1))
            let label = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : target
            var link = AttributedString(label)
            link.link = URL(string: "carnet-wiki://\(target.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? target)")
            link.foregroundColor = CarnetTheme.accent
            link.underlineStyle = .single
            out += link
            last = m.range.location + m.range.length
        }
        if last < ns.length { out += AttributedString(ns.substring(from: last)) }
        return out
    }

    /// [[basename]] → the garden entry it names ("sugar-fiche" and "sugar"
    /// both land on the entry "sugar").
    private func open(basename: String) async {
        guard !resolving else { return }
        resolving = true
        defer { resolving = false }
        let slug = basename.hasSuffix("-fiche") ? String(basename.dropLast("-fiche".count)) : basename
        guard let response = try? await GardenAPI.entries() else { return }
        if let entry = response.entries.first(where: { $0.slug == slug }) {
            username = response.garden.username
            opened = entry
        }
    }
}

// MARK: - Link-target picker
//
// The autocomplete half of the resonance gesture: type a few letters, pick
// the garden entry the thought belongs to. Search runs server-side over every
// collection (GET /garden/links/targets).

struct LinkTargetPicker: View {
    var onPick: (LinkTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [LinkTarget] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GridLabel("Link to…")
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)

            TextField("Search your notes", text: $query)
                .font(CarnetTheme.mono(13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(CarnetTheme.surface)
                .overlay(Rectangle().strokeBorder(CarnetTheme.ruleHard, lineWidth: 1))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .onChange(of: query) { _, q in search(q) }

            GridRule()

            if searching && results.isEmpty {
                GridLoading()
            } else if results.isEmpty {
                GridMessage(text: query.isEmpty ? "Type to search your notes."
                                                : "Nothing matches \"\(query)\".")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { t in
                            Button { onPick(t); dismiss() } label: {
                                TargetRow(target: t)
                            }
                            .buttonStyle(.plain)
                            GridRule()
                        }
                    }
                }
            }
        }
        .glassSheetBackground()
        .presentationDetents([.medium, .large])
        .onAppear { focused = true; search("") }
    }

    /// Debounced server search — one request ~250ms after the last keystroke.
    private func search(_ q: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            searching = true
            if let hits = try? await GardenAPI.linkTargets(query: q) {
                if !Task.isCancelled { results = hits }
            }
            searching = false
        }
    }

    private struct TargetRow: View {
        let target: LinkTarget
        private var collection: GardenCollection? { GardenCollection(rawValue: target.collection) }

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: collection?.symbol ?? "leaf")
                    .font(.system(size: 14))
                    .frame(width: 20)
                    .foregroundStyle(CarnetTheme.inkSoft)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title)
                        .font(CarnetTheme.sans(14.5, weight: .medium))
                        .foregroundStyle(CarnetTheme.ink)
                        .lineLimit(1)
                    GridLabel("\(collection?.label ?? target.collection) · [[\(target.linkBasename)]]",
                              size: 9, color: CarnetTheme.inkMute)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Resonance sheet
//
// The full gesture from a detail view: pick a target, write the note, send.
// The quote (when coming from a highlight or a selection) rides along.

struct ResonanceSheet: View {
    /// Label of what you're reading — the source of the thought.
    let sourceLabel: String
    /// [[basename]] of the source when it lives in the garden (article fiche).
    var sourceBasename: String? = nil
    /// Calibre-side source: the server matches the book to its garden fiche.
    var sourceBookTitle: String? = nil
    var quote: String? = nil
    var onDone: ((LinkTarget) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var target: LinkTarget?
    @State private var comment = ""
    @State private var picking = false
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GridLabel("Resonance")

            if let quote, !quote.isEmpty {
                Text(quote)
                    .font(CarnetTheme.sans(13.5))
                    .foregroundStyle(CarnetTheme.inkSoft)
                    .lineLimit(4)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CarnetTheme.surfaceAlt)
                    .overlay(alignment: .leading) { Rectangle().fill(CarnetTheme.accent).frame(width: 3) }
            }

            // Target — the fiche this feeds.
            Button { picking = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "leaf").font(.system(size: 14))
                    if let target {
                        Text(target.title).font(CarnetTheme.sans(14, weight: .semibold))
                        GridLabel("[[\(target.linkBasename)]]", size: 9, color: CarnetTheme.inkMute)
                    } else {
                        Text("Link to…").font(CarnetTheme.sans(14, weight: .medium))
                            .foregroundStyle(CarnetTheme.inkSoft)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CarnetTheme.inkMute)
                }
                .foregroundStyle(CarnetTheme.ink)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .overlay(Rectangle().strokeBorder(CarnetTheme.ruleHard, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            GridLabel("Note", size: 9)
            TextEditor(text: $comment)
                .font(CarnetTheme.sans(15))
                .frame(minHeight: 90)
                .overlay(Rectangle().strokeBorder(CarnetTheme.rule, lineWidth: 1))

            if let error {
                Text(error).font(CarnetTheme.caption).foregroundStyle(CarnetTheme.accent)
            }

            HStack {
                GridLabel("From \(sourceLabel)", size: 9, color: CarnetTheme.inkMute)
                    .lineLimit(1)
                Spacer()
                GridButton(title: "Cancel", small: true) { dismiss() }
                GridButton(title: sending ? "Sending…" : "Send", primary: true, small: true) {
                    Task { await send() }
                }
                .disabled(sending || target == nil ||
                          (comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (quote ?? "").isEmpty))
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassSheetBackground()
        .presentationDetents([.height(440), .large])
        .sheet(isPresented: $picking) {
            LinkTargetPicker { target = $0 }
        }
    }

    private func send() async {
        guard let target else { return }
        sending = true; error = nil
        do {
            // A Calibre book goes by title (the server finds its garden fiche);
            // anything else goes by label, wiki-linked when it has a basename.
            try await GardenAPI.createResonance(
                to: target,
                comment: comment.trimmingCharacters(in: .whitespacesAndNewlines),
                quote: quote,
                sourceLabel: sourceBookTitle == nil ? sourceLabel : nil,
                sourceBasename: sourceBasename,
                sourceBookTitle: sourceBookTitle)
            onDone?(target)
            dismiss()
        } catch {
            self.error = "Couldn't send.\n\(error.localizedDescription)"
        }
        sending = false
    }
}
