import SwiftUI

/// Maurice, from an entry. The member asks — typed or spoken — and Maurice
/// answers with the entry's fiche in hand. A conversation is rarely worth
/// keeping in itself; what is, is its result. So under each reply sits what
/// the exchange established: a note for this entry, and the other works and
/// people it touched, each kept by one gesture — on this entry, or as an entry
/// of its own linked to this one. A kept note carries a link back here, which
/// is how this screen is also opened on a past conversation.
struct AskMauriceView: View {
    /// What the conversation is held from. Nil when reading back a past one.
    let entry: ShelfEntry?
    /// Called when the screen closes, with whether anything was kept — the
    /// entry's page then reads itself again.
    var onClose: (_ kept: Bool) -> Void = { _ in }

    @State private var conversationId: String?
    @State private var title: String?
    @State private var turns: [Turn] = []
    @State private var draft = ""
    @State private var streaming = false
    @State private var working = false
    @State private var error: String?
    @State private var suggestions: [Suggestion] = []
    @State private var looking = false
    @State private var keptSomething = false
    @State private var loading: Bool
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    struct Turn: Identifiable, Hashable {
        let id = UUID()
        let mine: Bool
        var text: String
    }

    /// A new conversation, from an entry.
    init(entry: ShelfEntry, onClose: @escaping (Bool) -> Void = { _ in }) {
        self.entry = entry
        self.onClose = onClose
        _loading = State(initialValue: false)
    }

    /// A past conversation, read back from the link a kept note carries.
    init(conversationId: String) {
        self.entry = nil
        _conversationId = State(initialValue: conversationId)
        _loading = State(initialValue: true)
    }

    private var locale: Locale { Locale(identifier: entry?.locale ?? Locale.current.identifier) }
    private var pending: [Suggestion] { suggestions.filter { !$0.isKept } }
    private var kept: [Suggestion] { suggestions.filter(\.isKept) }
    private var canSend: Bool { !streaming && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if loading {
                            GridLoading().frame(minHeight: 200)
                        } else if turns.isEmpty {
                            opening
                        }
                        ForEach(turns) { turn in
                            TurnBlock(turn: turn, live: streaming && turn.id == turns.last?.id && !turn.mine, working: working)
                        }
                        if let error {
                            Text(error)
                                .font(CarnetTheme.sans(13)).foregroundStyle(CarnetTheme.inkSoft)
                                .padding(.horizontal, CarnetTheme.pageHorizontalPadding).padding(.top, 12)
                        }
                        keeping
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.bottom, 20)
                }
                .onChange(of: turns.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: suggestions) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            composer
        }
        .background(CarnetTheme.bg)
        .task { await loadPast() }
        .onAppear { if entry != nil { focused = true } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                GridLabel("Maurice", size: 9.5, color: CarnetTheme.inkSoft)
                Text(entry?.title ?? title ?? "Conversation")
                    .font(CarnetTheme.display(17))
                    .foregroundStyle(CarnetTheme.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            GridIconButton(systemName: "xmark", size: 36) { close() }
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.vertical, 12)
    }

    private func close() {
        onClose(keptSomething)
        dismiss()
    }

    /// Before the first question: what this is.
    private var opening: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask Maurice about this.")
                .font(CarnetTheme.sans(15)).foregroundStyle(CarnetTheme.inkSoft)
            Text("He reads what you keep on it. What the exchange is worth keeping comes back here, for you to keep on this entry.")
                .font(CarnetTheme.sans(13)).foregroundStyle(CarnetTheme.inkMute)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.top, 30)
    }

    // MARK: - What is worth keeping

    @ViewBuilder private var keeping: some View {
        if looking && pending.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(CarnetTheme.inkMute)
                GridLabel("What is worth keeping…", size: 9.5)
            }
            .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
            .padding(.top, 18)
        }
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                GridLabel("To keep", size: 9.5, color: CarnetTheme.inkSoft)
                ForEach(pending) { s in
                    SuggestionCard(suggestion: s,
                                   onKeep: { await keep(s, candidate: $0, episodes: $1) },
                                   onEpisodes: { try? await MauriceAPI.episodes(s.id, feed: $0) },
                                   onSearch: { await search(s, query: $0) },
                                   onDismiss: { dismissRow(s) })
                }
            }
            .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
            .padding(.top, 18)
        }
        if !kept.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                GridLabel("Kept", size: 9.5)
                ForEach(kept) { s in
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold))
                        Text(s.bound ? "On this entry" : s.title).font(CarnetTheme.sans(13))
                        if s.links && !s.bound {
                            Image(systemName: "link").font(.system(size: 9))
                        }
                    }
                    .foregroundStyle(CarnetTheme.inkSoft)
                }
            }
            .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
            .padding(.top, 16)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(turns.isEmpty ? "Ask Maurice…" : "Go on…", text: $draft, axis: .vertical)
                .font(CarnetTheme.sans(15.5))
                .lineLimit(1...6)
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(CarnetTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
            DictationMic(text: $draft, locale: locale, size: 44)
            Button { Task { await send() } } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CarnetTheme.accentInk)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(CarnetTheme.accent.opacity(canSend ? 1 : 0.3)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassFooter()
    }

    // MARK: - Work

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !streaming else { return }
        error = nil
        streaming = true
        working = true
        draft = ""
        // The reply is what there is to read now: the keyboard gets out of its way.
        focused = false
        turns.append(Turn(mine: true, text: text))
        do {
            if conversationId == nil, let ref = entry?.id {
                conversationId = try await MauriceAPI.open(from: ref)
            }
            guard let id = conversationId else { throw CarnetAPI.APIError.serverError("No conversation.") }
            turns.append(Turn(mine: false, text: ""))
            for try await event in MauriceAPI.send(text, to: id) {
                switch event {
                case .text(let t):
                    working = false
                    turns[turns.count - 1].text += t
                case .working:
                    working = true
                case .failed(let message):
                    error = message
                }
            }
        } catch {
            if !error.isCancellation { self.error = EntryView.message(error) }
            if turns.last?.mine == false, turns.last?.text.isEmpty == true { turns.removeLast() }
        }
        streaming = false
        working = false
        await look()
    }

    /// Once the reply is in: what the server found worth keeping in it.
    private func look() async {
        guard let id = conversationId else { return }
        looking = true
        if let list = try? await MauriceAPI.suggestions(for: id, settle: true) {
            suggestions = list.suggestions
        }
        looking = false
    }

    private func keep(_ s: Suggestion, candidate: String?, episodes: [String]) async -> Bool {
        do {
            try await MauriceAPI.keep(s.id, candidate: candidate, episodes: episodes)
            keptSomething = true
            if let id = conversationId, let list = try? await MauriceAPI.suggestions(for: id) {
                withAnimation { suggestions = list.suggestions }
            }
            return true
        } catch {
            self.error = EntryView.message(error)
            return false
        }
    }

    /// Another look; the number found, or nil when the call failed.
    private func search(_ s: Suggestion, query: String?) async -> Int? {
        do {
            let found = try await MauriceAPI.search(s.id, query: query)
            if let id = conversationId, let list = try? await MauriceAPI.suggestions(for: id) {
                withAnimation { suggestions = list.suggestions }
            }
            return found
        } catch {
            self.error = EntryView.message(error)
            return nil
        }
    }

    private func dismissRow(_ s: Suggestion) {
        withAnimation { suggestions.removeAll { $0.id == s.id } }
        Task { try? await MauriceAPI.dismiss(s.id) }
    }

    /// A past conversation: its messages, and what was kept of it.
    private func loadPast() async {
        guard loading, let id = conversationId else { return }
        do {
            let d = try await DomainsAPI.conversation(id: id)
            title = d.title
            turns = d.messages.map { Turn(mine: !$0.isMaurice, text: $0.content) }
            if let list = try? await MauriceAPI.suggestions(for: id) { suggestions = list.suggestions }
        } catch {
            if !error.isCancellation { self.error = "Couldn't load this conversation.\n\(error.localizedDescription)" }
        }
        loading = false
    }
}

// MARK: - One turn

private struct TurnBlock: View {
    let turn: AskMauriceView.Turn
    var live = false
    var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                GridLabel(turn.mine ? "You" : "Maurice", size: 9.5,
                          color: turn.mine ? CarnetTheme.inkMute : CarnetTheme.inkSoft)
                if live && (working || turn.text.isEmpty) {
                    ProgressView().controlSize(.mini).tint(CarnetTheme.inkMute)
                }
            }
            if turn.mine {
                Text(turn.text)
                    .font(CarnetTheme.sans(15)).foregroundStyle(CarnetTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !turn.text.isEmpty {
                // One text, selectable from end to end once it has arrived.
                ReplyText(markdown: turn.text, style: ReplyStyle(bodySize: 14.5, lineSpacing: 2.5),
                          selectable: !live)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.vertical, 14)
        .background(turn.mine ? CarnetTheme.surfaceAlt : Color.clear)
    }
}

// MARK: - One thing to keep

/// What would be kept, written out in full — the member reads it before it is
/// theirs — on the dotted paper it will land on, with the one gesture that
/// keeps it. For another work or person, the gesture also links it here.
struct SuggestionCard: View {
    let suggestion: Suggestion
    let onKeep: (String?, [String]) async -> Bool
    let onEpisodes: (String?) async -> EpisodeList?
    let onSearch: (String?) async -> Int?
    let onDismiss: () -> Void

    @State private var working = false
    @State private var picked: String?
    /// For a podcast: the episodes ticked, in the order they were — none for
    /// the show itself.
    @State private var episodes: [String] = []
    @State private var searching = false
    @State private var refining = false
    @State private var term = ""
    /// What the last look came back with, when it found nothing.
    @State private var nothing: String?
    @FocusState private var termFocused: Bool

    private var needsPick: Bool { !suggestion.candidates.isEmpty }
    private var canKeep: Bool { !needsPick || picked != nil }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: CarnetTheme.cardCornerRadius, style: .continuous) }

    private var state: String {
        if suggestion.bound { return "For this entry" }
        return suggestion.existing ? L("suggest.state_existing")
            : needsPick ? String(format: L("suggest.state_pick"), suggestion.candidates.count)
            : L("suggest.state_new")
    }

    private var action: String {
        if suggestion.bound { return L("suggest.keep") }
        if suggestion.links { return suggestion.existing ? "Add and link" : "Keep and link" }
        if episodes.count > 1 { return suggestion.links ? "Keep \(episodes.count) episodes and link" : String(format: L("suggest.keep_episodes"), episodes.count) }
        if episodes.count == 1 { return suggestion.links ? "Keep episode and link" : L("suggest.keep_episode") }
        // Asked for in the member's own words, an entry already theirs has
        // no note to add: keeping it opens it.
        if suggestion.existing && suggestion.note.isEmpty { return L("add.open") }
        return suggestion.existing ? L("suggest.add_note") : L("suggest.keep")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // As in the Maurice app: the poster, then what kind it is, the
            // title, the year and who made it, and whether it is yours yet.
            HStack(alignment: .top, spacing: 12) {
                SuggestionCover(image: suggestion.image, kind: suggestion.kind)
                VStack(alignment: .leading, spacing: 3) {
                    SuggestionKindPill(kind: suggestion.kind)
                        .padding(.bottom, 2)
                    Text(suggestion.title)
                        .font(CarnetTheme.sans(16, weight: .semibold)).foregroundStyle(CarnetTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    let identity = [suggestion.year.map(String.init), suggestion.subtitle]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !identity.isEmpty {
                        Text(identity).font(CarnetTheme.sans(12)).foregroundStyle(CarnetTheme.inkSoft)
                    }
                    Text(state)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(CarnetTheme.inkMute)
                        .padding(.top, 1)
                }
                Spacer(minLength: 4)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CarnetTheme.inkMute)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("suggest.dismiss"))
            }
            // The note, as it will read on the entry. A row asked for in the
            // member's own words carries none.
            if !suggestion.note.isEmpty {
                Text(suggestion.note)
                    .font(CarnetTheme.sans(14)).foregroundStyle(CarnetTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(CarnetTheme.inkMute.opacity(0.07)))
            }

            if needsPick {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestion.candidates) { c in
                        Button { picked = c.id } label: {
                            HStack(spacing: 10) {
                                Image(systemName: picked == c.id ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 15))
                                    .foregroundStyle(picked == c.id ? CarnetTheme.ink : CarnetTheme.inkMute)
                                SuggestionCover(image: c.image, kind: suggestion.kind, width: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.title).font(CarnetTheme.sans(13, weight: .medium)).foregroundStyle(CarnetTheme.ink)
                                    Text([c.year.map(String.init), c.subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(CarnetTheme.sans(11)).foregroundStyle(CarnetTheme.inkSoft)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // A show: which episode? Listed once the show is settled — the
            // suggestion's own, or the candidate picked.
            if suggestion.kind == "podcasts", !suggestion.bound, !needsPick || picked != nil {
                EpisodePicker(feed: needsPick ? picked : nil, onEpisodes: onEpisodes, selection: $episodes)
                    .id("\(suggestion.candidates.map(\.id).joined(separator: ","))|\(picked ?? "")")
            }

            HStack(spacing: 10) {
                Button {
                    working = true
                    Task {
                        _ = await onKeep(picked, episodes)
                        working = false
                    }
                } label: {
                    Text(action)
                        .font(CarnetTheme.sans(13, weight: .medium))
                        .foregroundStyle(CarnetTheme.bg)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(CarnetTheme.ink.opacity(canKeep ? 1 : 0.3)))
                }
                .buttonStyle(.plain)
                .disabled(working || !canKeep)
                if working { ProgressView().controlSize(.small) }
            }

            if suggestion.searchable == true { lookAgain }
        }
        // One possibility is the one: picked at once, so a show lists its
        // episodes without a tap that says nothing.
        .onChange(of: suggestion.candidates.map(\.id), initial: true) { _, ids in
            if ids.count == 1 { picked = ids[0] }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(CarnetTheme.bg))
        .overlay(shape.strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
    }
}

// MARK: - Another look

/// Not the right one: Maurice looks again, or the member says what to look for.
private extension SuggestionCard {
    var lookAgain: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Button { Task { await look(nil) } } label: {
                    Label(L("suggest.search_again"), systemImage: "arrow.clockwise")
                }
                Button {
                    refining.toggle()
                    if refining {
                        term = suggestion.query ?? suggestion.title
                        termFocused = true
                    }
                } label: {
                    Label(L("suggest.search_refine"), systemImage: "magnifyingglass")
                }
                if searching { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
            .font(CarnetTheme.sans(12.5, weight: .medium))
            .foregroundStyle(CarnetTheme.inkSoft)
            .disabled(searching || working)

            if refining {
                HStack(spacing: 8) {
                    TextField(L("suggest.search_placeholder"), text: $term)
                        .font(CarnetTheme.sans(14))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($termFocused)
                        .onSubmit { Task { await look(term) } }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
                    GridButton(title: L("suggest.search_go"), small: true) { Task { await look(term) } }
                        .disabled(searching || term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if let nothing {
                Text(nothing).font(CarnetTheme.sans(12)).foregroundStyle(CarnetTheme.inkMute)
            }
        }
    }

    func look(_ query: String?) async {
        let typed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let typed, typed.isEmpty { return }
        searching = true
        nothing = nil
        let found = await onSearch(typed)
        searching = false
        guard let found else { return }
        if found == 0 {
            nothing = typed.map { String(format: L("suggest.search_nothing"), $0) } ?? L("suggest.search_nothing_new")
        } else {
            // A new list: the pick made on the old one no longer holds.
            picked = nil
            refining = false
        }
    }
}

// MARK: - A show's episodes

/// A show's recent episodes, as a podcast app lists them: the day, the title,
/// what it is about, the length, the art — the one Maurice reads the
/// conversation as being about ticked in advance. Each is ticked on its own;
/// none ticked leaves the show itself to be kept.
private struct EpisodePicker: View {
    let feed: String?
    let onEpisodes: (String?) async -> EpisodeList?
    @Binding var selection: [String]

    @State private var list: EpisodeList?
    @State private var loading = true
    @State private var shown = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("suggest.episodes_loading")).font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkMute)
                }
                .padding(.vertical, 6)
            } else if let list, !list.episodes.isEmpty {
                GridLabel(L("suggest.episodes"), size: 9.5, color: CarnetTheme.inkSoft).padding(.bottom, 2)
                ForEach(Array(list.episodes.prefix(shown).enumerated()), id: \.element.id) { i, ep in
                    if i > 0 { Rectangle().fill(CarnetTheme.rule).frame(height: CarnetTheme.hairline) }
                    row(ep, suggested: ep.id == list.suggested)
                }
                if list.episodes.count > shown {
                    Button(L("suggest.episodes_more")) { withAnimation { shown += 10 } }
                        .buttonStyle(.plain)
                        .font(CarnetTheme.sans(12.5, weight: .medium))
                        .foregroundStyle(CarnetTheme.inkSoft)
                        .padding(.top, 8)
                }
                Text("With no episode ticked, the show is kept.")
                    .font(CarnetTheme.sans(11.5)).foregroundStyle(CarnetTheme.inkMute)
                    .padding(.top, 6)
            }
        }
        .task {
            let got = await onEpisodes(feed)
            list = got
            if let got, let suggested = got.suggested, let at = got.episodes.firstIndex(where: { $0.id == suggested }) {
                selection = [suggested]
                shown = max(shown, at + 1)
            } else {
                selection = []
            }
            loading = false
        }
    }

    private func row(_ ep: EpisodeList.Episode, suggested: Bool) -> some View {
        let on = selection.contains(ep.id)
        return Button {
            if on { selection.removeAll { $0 == ep.id } } else { selection.append(ep.id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(on ? CarnetTheme.ink : CarnetTheme.inkMute)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let when = Self.when(ep.date) {
                            Text(when).font(CarnetTheme.sans(11, weight: .semibold)).foregroundStyle(CarnetTheme.inkMute)
                        }
                        if suggested {
                            Text(L("suggest.episode_suggested"))
                                .font(CarnetTheme.sans(10, weight: .semibold)).foregroundStyle(CarnetTheme.inkSoft)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(CarnetTheme.rule))
                        }
                    }
                    Text(ep.title)
                        .font(CarnetTheme.sans(14, weight: .semibold)).foregroundStyle(CarnetTheme.ink)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if !ep.description.isEmpty {
                        Text(ep.description)
                            .font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkSoft)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                    if let length = Self.length(ep.duration) {
                        Text(length)
                            .font(CarnetTheme.sans(11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(CarnetTheme.inkSoft)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(CarnetTheme.rule))
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 6)
                art(ep.image)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func art(_ image: String) -> some View {
        AsyncImage(url: URL(string: image)) { phase in
            if case .success(let img) = phase {
                img.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    CarnetTheme.rule
                    Image(systemName: "mic").font(.system(size: 18)).foregroundStyle(CarnetTheme.inkMute)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// "20 hr. ago" within the week, the day otherwise.
    static func when(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        if Date().timeIntervalSince(date) < 7 * 86_400 {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            return f.localizedString(for: date, relativeTo: Date())
        }
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year())
    }

    /// "33 min", "1 hr, 5 min".
    static func length(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .short
        return f.string(from: TimeInterval(seconds))
    }
}
