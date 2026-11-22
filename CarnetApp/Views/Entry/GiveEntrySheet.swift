import SwiftUI

// Giving an entry to someone in another household this device is signed
// into (maurice/specs/cross-household-share.md, section D). The entry is
// copied there — a gift, not a link: the member ticks every element that
// leaves, sees all of it in a preview whose button is the only « Send », and
// the copy lands in their own notes over there, shared with that person.
// The member may also copy it to their own notes over there, shared with no
// one (« Me — in my notes »): the same sheet and preview, without `share_with`.

/// Someone in another household — or the member themselves there — and how
/// to reach that household.
struct GiveRecipient: Identifiable, Hashable {
    let household: Household
    let target: CrossHouseholdAPI.Target
    let member: CarnetAPI.Member
    /// The member's own account over there: the entry is copied into their
    /// notes and shared with no one.
    var isSelf = false
    var id: String { "\(household.id)/\(member.id)" }
}

// MARK: - The sections in the share sheet

/// One section per other household of the device: the people the member can
/// reach there, read with that household's own session. Choosing someone
/// opens the sending sheet.
struct OtherHouseholdsSection: View {
    let entry: ShelfEntry
    /// The share sheet closes when the copy is opened over there.
    var onOpened: () -> Void = {}

    @Environment(CarnetSession.self) private var session
    @State private var rosters: [String: RosterState] = [:]
    @State private var giving: GiveRecipient?

    enum RosterState {
        /// The people the member can give to there, and the member's own
        /// account there (to copy the entry into their own notes).
        case loading, people([CarnetAPI.Member], me: CarnetAPI.Member), failed, noSession
    }

    private var others: [Household] {
        session.households.filter { $0.id != session.currentHouseholdId }
    }

    var body: some View {
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(others) { household in
                    section(household)
                }
            }
            .task { await load() }
            .sheet(item: $giving) { recipient in
                GiveEntrySheet(entry: entry, recipient: recipient,
                               fromHousehold: session.currentHouseholdName,
                               onOpened: onOpened)
            }
        }
    }

    private func section(_ household: Household) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GridLabel(L("give.section", household.name), size: 9.5).padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            Text(L("give.section.hint"))
                .font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkMute)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
            switch rosters[household.id] ?? .loading {
            case .loading:
                line(L("give.section.loading"))
            case .noSession:
                line(L("give.section.signin", household.name))
            case .failed:
                line(L("give.error.offline", household.name))
            case .people(let people, let me):
                // First, the member themselves: their own notes over there.
                person(me, name: L("give.self.row"), button: L("give.self.copy")) {
                    guard let target = target(household) else { return }
                    giving = GiveRecipient(household: household, target: target.0, member: me, isSelf: true)
                }
                if people.isEmpty {
                    line(L("give.section.empty"))
                }
                ForEach(people) { member in
                    person(member, name: member.display_name, button: L("give.choose")) {
                        guard let target = target(household) else { return }
                        giving = GiveRecipient(household: household, target: target.0, member: member)
                    }
                }
            }
        }
    }

    private func person(_ member: CarnetAPI.Member, name: String, button: String, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            MemberBadge(member: member, size: 30)
            Text(name).font(CarnetTheme.sans(15, weight: .medium)).foregroundStyle(CarnetTheme.ink)
            Spacer(minLength: 0)
            GridButton(title: button, small: true, action: action)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { GridRule() }
    }

    private func line(_ text: String) -> some View {
        Text(text).font(CarnetTheme.sans(13)).foregroundStyle(CarnetTheme.inkMute).padding(.vertical, 10)
    }

    /// A session of the member's in that household: the active one there,
    /// or any other member of this device signed in there.
    private func target(_ household: Household) -> (CrossHouseholdAPI.Target, String)? {
        let candidates = [household.activeMemberId].compactMap { $0 } + household.deviceMembers.map(\.id)
        for id in candidates {
            if let token = session.token(householdId: household.id, memberId: id) {
                return (CrossHouseholdAPI.Target(serverURL: household.serverURL, token: token), id)
            }
        }
        return nil
    }

    private func load() async {
        // The households' own names, for the sections' headings.
        await session.refreshHouseholdIdentities()
        var reachable: [(Household, CrossHouseholdAPI.Target, String)] = []
        for household in others {
            if let (target, me) = target(household) {
                reachable.append((household, target, me))
            } else {
                rosters[household.id] = .noSession
            }
        }
        let found = await withTaskGroup(of: (Household, String, [CarnetAPI.Member]?).self) { group in
            for (household, target, me) in reachable {
                group.addTask { (household, me, try? await CrossHouseholdAPI.roster(target)) }
            }
            var all: [(Household, String, [CarnetAPI.Member]?)] = []
            for await result in group { all.append(result) }
            return all
        }
        for (household, me, people) in found {
            guard let people else { rosters[household.id] = .failed; continue }
            // The member's own account there: as the household lists it, else
            // as this device keeps it.
            guard let mine = people.first(where: { $0.id == me }) ?? household.deviceMembers.first(where: { $0.id == me }) else {
                rosters[household.id] = .failed; continue
            }
            rosters[household.id] = .people(people.filter { $0.id != me }.map { Self.absolute($0, server: household.serverURL) },
                                            me: Self.absolute(mine, server: household.serverURL))
        }
    }

    /// A picture's path is on that household's server, not the one on screen.
    private static func absolute(_ member: CarnetAPI.Member, server: String) -> CarnetAPI.Member {
        var m = member
        if let path = m.avatar_url, path.hasPrefix("/") { m.avatar_url = server + path }
        return m
    }
}

// MARK: - What leaves

/// What the member ticked. Everything is unticked but the source.
struct GiveSelection: Hashable {
    enum Mode: Hashable { case summary, whole }

    var source = true
    var prose = false
    var notes: Set<String> = []
    var highlights: Set<String> = []
    var card = false
    var conversations: [String: Mode] = [:]
}

// MARK: - The sending sheet

struct GiveEntrySheet: View {
    let entry: ShelfEntry
    let recipient: GiveRecipient
    /// The name of the household on screen, which B is told.
    let fromHousehold: String
    var onOpened: () -> Void = {}

    @State private var export: EntryExport?
    @State private var failure: String?
    @State private var selection = GiveSelection()
    @State private var previewing = false
    @Environment(\.dismiss) private var dismiss

    init(entry: ShelfEntry, recipient: GiveRecipient, fromHousehold: String,
         export: EntryExport? = nil, onOpened: @escaping () -> Void = {}) {
        self.entry = entry
        self.recipient = recipient
        self.fromHousehold = fromHousehold
        self.onOpened = onOpened
        _export = State(initialValue: export)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let export {
                    form(export)
                } else if let failure {
                    GridMessage(text: failure)
                } else {
                    GridLoading()
                }
            }
            .background(CarnetTheme.bg)
            .navigationTitle(recipient.isSelf
                             ? L("give.self.title", recipient.household.name)
                             : L("give.title", recipient.member.display_name, recipient.household.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L("common.cancel"))
                }
            }
            .navigationDestination(isPresented: $previewing) {
                if let export {
                    GivePreview(export: export, selection: selection, recipient: recipient,
                                fromHousehold: fromHousehold) {
                        dismiss()
                        onOpened()
                    }
                }
            }
        }
        .tint(CarnetTheme.ink)
        .task { if export == nil { await load() } }
    }

    private func load() async {
        guard let c = entry.collection, let l = entry.locale, let s = entry.slug,
              let current = CrossHouseholdAPI.current else {
            failure = L("give.load_failed", "—")
            return
        }
        do {
            export = try await CrossHouseholdAPI.export(current, collection: c, locale: l, slug: s)
        } catch {
            failure = L("give.load_failed", GiveMessages.describe(error, recipient: recipient))
        }
    }

    // MARK: Form

    private func form(_ e: EntryExport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if e.source != nil {
                    TickRow(state: selection.source ? .on : .off,
                            title: GiveMessages.sourceLabel(e.sourceKind),
                            detail: "« \(e.title) »") {
                        selection.source.toggle()
                    }
                }

                ficheGroup(e)

                if let highlights = e.highlights, !highlights.isEmpty {
                    highlightsGroup(highlights)
                }

                if let card = e.card {
                    TickRow(state: selection.card ? .on : .off,
                            title: L(card.isDraft ? "give.card.draft" : "give.card.published"),
                            detail: card.isDraft ? nil : L("give.card.hint")) {
                        selection.card.toggle()
                    }
                }

                if let conversations = e.conversations, !conversations.isEmpty {
                    conversationsGroup(conversations)
                }

                GridButton(title: L("give.preview_button"), primary: true, full: true) {
                    previewing = true
                }
                .padding(.top, 24)
            }
            .padding(20)
        }
    }

    @ViewBuilder private func ficheGroup(_ e: EntryExport) -> some View {
        let prose = (e.fiche?.prose?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let notes = e.fiche?.notes ?? []
        if prose != nil || !notes.isEmpty {
            let count = (prose != nil ? 1 : 0) + notes.count
            let ticked = (prose != nil && selection.prose ? 1 : 0) + notes.filter { selection.notes.contains($0.id) }.count
            TickRow(state: .of(ticked, count), title: L("give.fiche")) {
                let on = ticked < count
                selection.prose = on && prose != nil
                selection.notes = on ? Set(notes.map(\.id)) : []
            }
            if prose != nil {
                TickRow(state: selection.prose ? .on : .off, title: L("give.fiche.prose"), level: 1) {
                    selection.prose.toggle()
                }
            }
            ForEach(notes) { note in
                TickRow(state: selection.notes.contains(note.id) ? .on : .off,
                        title: GiveMessages.noteLine(note), level: 1, lines: 2) {
                    selection.notes.formSymmetricDifference([note.id])
                }
            }
        }
    }

    @ViewBuilder private func highlightsGroup(_ highlights: [EntryExport.Highlight]) -> some View {
        let ticked = highlights.filter { selection.highlights.contains($0.id) }.count
        TickRow(state: .of(ticked, highlights.count), title: L("give.highlights", highlights.count)) {
            selection.highlights = ticked < highlights.count ? Set(highlights.map(\.id)) : []
        }
        // Each passage can be let go once the group is ticked.
        if ticked > 0 {
            ForEach(highlights) { h in
                TickRow(state: selection.highlights.contains(h.id) ? .on : .off,
                        title: "« \(h.text) »", level: 1, lines: 2) {
                    selection.highlights.formSymmetricDifference([h.id])
                }
            }
        }
    }

    @ViewBuilder private func conversationsGroup(_ conversations: [EntryExport.Conversation]) -> some View {
        let open = conversations.filter(\.shareable)
        let ticked = open.filter { selection.conversations[$0.id] != nil }.count
        TickRow(state: open.isEmpty ? .disabled : .of(ticked, open.count), title: L("give.conversations")) {
            if ticked < open.count {
                for c in open where selection.conversations[c.id] == nil {
                    selection.conversations[c.id] = c.summary == nil ? .whole : .summary
                }
            } else {
                selection.conversations = [:]
            }
        }
        ForEach(conversations) { c in
            let title = GiveMessages.conversationLine(c)
            if c.shareable {
                TickRow(state: selection.conversations[c.id] != nil ? .on : .off, title: title, level: 1) {
                    selection.conversations[c.id] = selection.conversations[c.id] == nil
                        ? (c.summary == nil ? .whole : .summary) : nil
                }
                if let mode = selection.conversations[c.id] {
                    modePicker(c, mode: mode)
                }
            } else {
                TickRow(state: .disabled, title: title,
                        detail: c.reason == nil || c.reason == "others_took_part" ? L("give.conv.others") : c.reason,
                        level: 1)
            }
        }
        Text(L("give.conv.review"))
            .font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
    }

    private func modePicker(_ c: EntryExport.Conversation, mode: GiveSelection.Mode) -> some View {
        HStack(spacing: 18) {
            radio(L("give.conv.summary"), on: mode == .summary, enabled: c.summary != nil) {
                selection.conversations[c.id] = .summary
            }
            radio(L("give.conv.whole"), on: mode == .whole, enabled: true) {
                selection.conversations[c.id] = .whole
            }
        }
        .padding(.leading, 2 * TickRow.indent + 4)
        .padding(.bottom, 8)
    }

    private func radio(_ title: String, on: Bool, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                Text(title)
            }
            .font(CarnetTheme.sans(13))
            .foregroundStyle(enabled ? CarnetTheme.ink : CarnetTheme.inkHint)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// One line of the sheet: a box, its title, an optional second line.
private struct TickRow: View {
    enum Mark {
        case on, off, mixed, disabled
        static func of(_ ticked: Int, _ count: Int) -> Mark {
            ticked == 0 ? .off : ticked == count ? .on : .mixed
        }
    }
    static let indent: CGFloat = 26

    let state: Mark
    let title: String
    var detail: String? = nil
    var level = 0
    var lines = 1
    var action: (() -> Void)? = nil

    private var glyph: String {
        switch state {
        case .on: return "checkmark.square.fill"
        case .off: return "square"
        case .mixed: return "minus.square.fill"
        case .disabled: return "nosign"
        }
    }

    var body: some View {
        Button { action?() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: glyph)
                    .font(.system(size: 16))
                    .foregroundStyle(state == .disabled ? CarnetTheme.inkHint : CarnetTheme.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(CarnetTheme.sans(level == 0 ? 15 : 14, weight: level == 0 ? .semibold : .regular))
                        .foregroundStyle(state == .disabled ? CarnetTheme.inkMute : CarnetTheme.ink)
                        .lineLimit(lines)
                    if let detail {
                        Text(detail).font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkMute).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(level) * Self.indent)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state == .disabled || action == nil)
        .accessibilityAddTraits(state == .on ? .isSelected : [])
    }
}

// MARK: - The preview

/// The entry as it will arrive over there: the source, the member's face
/// (prose, notes, passages as quotes, conversations kept as their summary),
/// the card in draft, each conversation sent whole in full. Its button is
/// the only « Send ».
struct GivePreview: View {
    let export: EntryExport
    let selection: GiveSelection
    let recipient: GiveRecipient
    let fromHousehold: String
    var onOpened: () -> Void

    @Environment(CarnetSession.self) private var session
    @Environment(CarnetRouter.self) private var router

    @State private var wholes: [String: ConversationExport]
    @State private var conversationFailure: String?
    @State private var sending = false
    @State private var outcome: Outcome?
    @State private var fullText = false

    enum Outcome {
        case sent(CrossHouseholdAPI.Imported)
        case exists(String)
        case failed(String)
    }

    init(export: EntryExport, selection: GiveSelection, recipient: GiveRecipient, fromHousehold: String,
         wholes: [String: ConversationExport] = [:], onOpened: @escaping () -> Void) {
        self.export = export
        self.selection = selection
        self.recipient = recipient
        self.fromHousehold = fromHousehold
        self.onOpened = onOpened
        _wholes = State(initialValue: wholes)
    }

    private var name: String { recipient.member.display_name }

    private var notes: [EntryExport.Note] { (export.fiche?.notes ?? []).filter { selection.notes.contains($0.id) } }
    private var highlights: [EntryExport.Highlight] { (export.highlights ?? []).filter { selection.highlights.contains($0.id) } }
    private var prose: String? { selection.prose ? export.fiche?.prose : nil }
    private var conversations: [(EntryExport.Conversation, GiveSelection.Mode)] {
        (export.conversations ?? []).compactMap { c in
            guard c.shareable, let mode = selection.conversations[c.id] else { return nil }
            return (c, mode)
        }
    }
    private var summaries: [EntryExport.Conversation] { conversations.filter { $0.1 == .summary }.map(\.0) }
    private var fulls: [EntryExport.Conversation] { conversations.filter { $0.1 == .whole }.map(\.0) }
    private var ready: Bool { fulls.allSatisfy { wholes[$0.id] != nil } }

    private var hasMine: Bool { prose != nil || !notes.isEmpty || !highlights.isEmpty || !summaries.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if selection.source, export.source != nil { sourceBlock }
                if hasMine { mineFace }
                if selection.card, let card = export.card { cardFace(card) }
                ForEach(fulls) { c in conversationBlock(c) }
                if !selection.source && !hasMine && !selection.card && fulls.isEmpty {
                    Text(L("give.preview.nothing"))
                        .font(CarnetTheme.sans(13)).foregroundStyle(CarnetTheme.inkMute)
                }
            }
            .padding(20)
            .padding(.bottom, 12)
        }
        .background(CarnetTheme.bg)
        .navigationTitle(L("give.preview.title"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer.glassFooter() }
        .task { await loadConversations() }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            GridLabel(recipient.isSelf ? L("give.self.kicker", recipient.household.name)
                                       : L("give.preview.kicker", recipient.household.name),
                      size: 9.5, color: CarnetTheme.inkSoft)
            Text(export.title)
                .font(CarnetTheme.display(24, weight: .bold))
                .foregroundStyle(CarnetTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let author = export.author {
                Text(author).font(CarnetTheme.sans(14)).foregroundStyle(CarnetTheme.inkSoft)
            }
            Text(recipient.isSelf ? L("give.self.given", fromHousehold) : L("give.preview.given", fromHousehold))
                .font(CarnetTheme.mono(10)).foregroundStyle(CarnetTheme.inkMute)
        }
    }

    @ViewBuilder private var sourceBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            GridLabel(GiveMessages.sourceLabel(export.sourceKind), size: 9.5)
            if export.sourceKind == "book" {
                let calibre = export.source?["calibre"]
                Text(calibre?["title"]?.string ?? export.title)
                    .font(CarnetTheme.sans(15, weight: .medium)).foregroundStyle(CarnetTheme.ink)
                let authors = calibre?["authors"]?.strings ?? []
                if !authors.isEmpty {
                    Text(authors.joined(separator: ", ")).font(CarnetTheme.sans(13)).foregroundStyle(CarnetTheme.inkSoft)
                }
                Text(L("give.preview.book_record"))
                    .font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkMute)
            } else {
                let text = export.source?["text"]?.string ?? GiveMessages.plainText(export.source?["html"]?.string ?? "")
                if text.isEmpty {
                    Text(export.title).font(CarnetTheme.sans(14)).foregroundStyle(CarnetTheme.inkSoft)
                } else {
                    Text(text)
                        .font(.system(size: 15, design: .serif))
                        .foregroundStyle(CarnetTheme.ink)
                        .lineLimit(fullText ? nil : 8)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L(fullText ? "give.show_less" : "give.show_all")) { fullText.toggle() }
                        .font(CarnetTheme.sans(13, weight: .medium))
                        .foregroundStyle(CarnetTheme.ink)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(CarnetTheme.surfaceAlt))
    }

    private var mineFace: some View {
        VStack(alignment: .leading, spacing: 14) {
            GridLabel(L("give.preview.mine"), size: 9.5, color: CarnetTheme.inkSoft)
            if let prose, !prose.isEmpty {
                MarkdownBlocks(text: prose, serif: false)
            }
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 6) {
                    GridLabel(GiveMessages.noteHeading(note), size: 9.5)
                    if let quote = note.quote, !quote.isEmpty {
                        MarkdownBlocks(text: "> " + quote, serif: false)
                    }
                    MarkdownBlocks(text: note.text, serif: false)
                }
            }
            ForEach(highlights) { h in
                VStack(alignment: .leading, spacing: 4) {
                    MarkdownBlocks(text: "> " + h.text, serif: false)
                    if let chapter = h.chapter, !chapter.isEmpty {
                        Text(chapter).font(CarnetTheme.mono(10)).foregroundStyle(CarnetTheme.inkMute).padding(.leading, 11)
                    }
                    if let note = h.note, !note.isEmpty {
                        Text(note).font(CarnetTheme.sans(13.5)).foregroundStyle(CarnetTheme.ink).padding(.leading, 11)
                    }
                }
            }
            ForEach(summaries) { c in
                VStack(alignment: .leading, spacing: 6) {
                    GridLabel(GiveMessages.dateLabel(c.date) ?? "", size: 9.5)
                    Text(L("give.preview.conv_note", GiveMessages.dateLabel(c.date) ?? "", c.summary ?? ""))
                        .font(CarnetTheme.sans(14)).foregroundStyle(CarnetTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(.mine, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(CarnetTheme.rule, lineWidth: CarnetTheme.hairline))
    }

    private func cardFace(_ card: EntryExport.Card) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GridLabel(L("give.preview.card"), size: 9.5, color: CarnetTheme.inkSoft)
            MarkdownBlocks(text: SharedBody.withoutTitle(card.body, title: export.title), serif: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(.shared, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(CarnetTheme.rule, lineWidth: CarnetTheme.hairline))
    }

    private func conversationBlock(_ c: EntryExport.Conversation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                GridLabel(L("give.preview.conv_label", fromHousehold), size: 9.5, color: CarnetTheme.inkSoft)
                Text(wholes[c.id]?.title ?? c.title ?? "Maurice")
                    .font(CarnetTheme.display(18, weight: .bold)).foregroundStyle(CarnetTheme.ink)
                if let date = GiveMessages.dateLabel(c.date) {
                    Text(date).font(CarnetTheme.mono(10)).foregroundStyle(CarnetTheme.inkMute)
                }
            }
            .padding(16)
            GridRule()
            if let whole = wholes[c.id] {
                ForEach(Array(whole.messages.enumerated()), id: \.offset) { _, m in
                    VStack(alignment: .leading, spacing: 8) {
                        GridLabel(m.isMaurice ? "Maurice" : (m.author ?? L("give.preview.you")), size: 9.5,
                                  color: m.isMaurice ? CarnetTheme.inkSoft : CarnetTheme.inkMute)
                        ReplyText(markdown: m.text)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(m.isMaurice ? Color.clear : CarnetTheme.surfaceAlt)
                    GridRule()
                }
            } else if let conversationFailure {
                Text(conversationFailure).font(CarnetTheme.sans(13)).foregroundStyle(CarnetTheme.inkSoft).padding(16)
            } else {
                ProgressView().tint(CarnetTheme.inkMute).frame(maxWidth: .infinity).padding(24)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch outcome {
            case .sent(let imported):
                // Copied to one's own notes, there is no one to talk it over with.
                Text(recipient.isSelf ? L("give.self.sent", recipient.household.name)
                                      : L("give.sent", name, recipient.household.name))
                    .font(CarnetTheme.sans(14)).foregroundStyle(CarnetTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                GridButton(title: L("give.open"), primary: true, full: true) { open(imported.ref) }
            case .exists(let ref):
                Text(recipient.isSelf ? L("give.self.exists", recipient.household.name)
                                      : L("give.error.exists", name, recipient.household.name))
                    .font(CarnetTheme.sans(14)).foregroundStyle(CarnetTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                GridButton(title: L("give.open"), primary: true, full: true) { open(ref) }
            case .failed(let message):
                Text(message).font(CarnetTheme.sans(13.5)).foregroundStyle(CarnetTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                sendButton
            case nil:
                sendButton
            }
        }
        .padding(16)
    }

    private var sendButton: some View {
        Group {
            if sending {
                HStack(spacing: 8) {
                    ProgressView().tint(CarnetTheme.inkMute)
                    Text(L(recipient.isSelf ? "give.self.sending" : "give.sending")).font(CarnetTheme.sans(14)).foregroundStyle(CarnetTheme.inkSoft)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 13)
            } else {
                GridButton(title: recipient.isSelf ? L("give.self.copy") : L("give.send", name),
                           primary: true, full: true) { Task { await send() } }
                    .disabled(!ready)
            }
        }
    }

    // MARK: Actions

    private func loadConversations() async {
        guard let current = CrossHouseholdAPI.current else { return }
        for c in fulls where wholes[c.id] == nil {
            do {
                wholes[c.id] = try await CrossHouseholdAPI.conversation(current, id: c.id)
            } catch {
                conversationFailure = L("give.preview.conv_failed", GiveMessages.describe(error, recipient: recipient))
            }
        }
    }

    private func send() async {
        guard ready else { return }
        sending = true
        defer { sending = false }
        var payload = ImportPayload(entry: export.entry, fromHousehold: fromHousehold)
        if selection.source { payload.source = export.source }
        payload.prose = prose
        payload.notes = notes.map(\.raw)
        payload.highlights = highlights.map(\.raw)
        if selection.card { payload.card = export.card }
        payload.conversations = conversations.map { c, mode in (c, mode == .whole ? wholes[c.id] : nil) }
        // Into the member's own notes there: shared with no one.
        payload.shareWith = recipient.isSelf ? nil : (recipient.member.username ?? recipient.member.id)
        do {
            let imported = try await CrossHouseholdAPI.importEntry(recipient.target, payload)
            withAnimation { outcome = .sent(imported) }
        } catch CrossHouseholdAPI.Failure.exists(let c, let l, let s) {
            withAnimation { outcome = .exists("\(c)/\(l)/\(s)") }
        } catch {
            withAnimation { outcome = .failed(GiveMessages.describe(error, recipient: recipient)) }
        }
    }

    /// Over to the other household, on the copy.
    private func open(_ ref: String) {
        onOpened()
        session.switchHousehold(recipient.household.id)
        router.openEntryId = ref
    }
}

// MARK: - Words

enum GiveMessages {
    static func sourceLabel(_ kind: String?) -> String {
        switch kind {
        case "article": return L("give.source.article")
        case "book": return L("give.source.book")
        default: return L("give.source.other")
        }
    }

    /// « 12 mars » from "2026-03-12" (or any date the server writes).
    static func dateLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let day = String(raw.prefix(10))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: day) ?? ServerDate.parse(raw) else { return raw }
        let out = DateFormatter()
        out.locale = AppLanguage.locale
        out.timeZone = TimeZone(identifier: "UTC")
        out.setLocalizedDateFormatFromTemplate(
            Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "dMMMM" : "dMMMMyyyy")
        return out.string(from: date)
    }

    /// « 12 mars — « Relire le passage… » » / « 14 mars — p. 32 : « … » »
    static func noteLine(_ note: EntryExport.Note) -> String {
        let text = note.text.replacingOccurrences(of: "\n", with: " ")
        let body = note.pageLabel.map { L("give.note.page", $0, text) } ?? "« \(text) »"
        return [dateLabel(note.date), body].compactMap { $0 }.joined(separator: " — ")
    }

    static func noteHeading(_ note: EntryExport.Note) -> String {
        [dateLabel(note.date), note.pageLabel.map { "p. \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    static func conversationLine(_ c: EntryExport.Conversation) -> String {
        [dateLabel(c.date), c.title].compactMap { $0 }.joined(separator: " · ")
    }

    /// An error said in the app's language, naming the person and the household.
    static func describe(_ error: Error, recipient: GiveRecipient) -> String {
        let place = recipient.household.name
        switch error {
        case CrossHouseholdAPI.Failure.offline: return L("give.error.offline", place)
        case CrossHouseholdAPI.Failure.forbidden("others_took_part"): return L("give.conv.others")
        case CrossHouseholdAPI.Failure.unreachable, CrossHouseholdAPI.Failure.forbidden: return L("give.error.unreachable", recipient.member.display_name, place)
        case CrossHouseholdAPI.Failure.sessionEnded: return L("give.error.session", place)
        case CrossHouseholdAPI.Failure.unsupported: return L("give.error.unsupported", place)
        case CrossHouseholdAPI.Failure.tooLarge: return L("give.error.too_large", place)
        case CrossHouseholdAPI.Failure.exists:
            return recipient.isSelf ? L("give.self.exists", place) : L("give.error.exists", recipient.member.display_name, place)
        case CrossHouseholdAPI.Failure.refused(let code):
            // The server says the person cannot be shared with any more.
            if ["not_reachable", "unreachable", "unknown_member", "not_a_contact", "forbidden", "share_with"].contains(code)
                || code.contains("reach") {
                return L("give.error.unreachable", recipient.member.display_name, place)
            }
            return code
        case CrossHouseholdAPI.Failure.other(let message): return message
        default: return error.localizedDescription
        }
    }

    /// The captured page as plain paragraphs, for the preview.
    static func plainText(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        var s = html
        for (pattern, replacement) in [
            ("(?is)<(script|style)[^>]*>.*?</\\1>", ""),
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</(p|div|h[1-6]|li|blockquote)>", "\n\n"),
            ("<[^>]+>", ""),
        ] {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                               ("&quot;", "\""), ("&#39;", "'"), ("&rsquo;", "’"), ("&laquo;", "«"), ("&raquo;", "»")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n\\s*(\\n\\s*)+", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
