import SwiftUI

/// One entry, opened. Identity on top; then the source, when there is one —
/// a sunken band that is not paper, since those are someone else's words —
/// and then a single sheet with two faces: the member's side, on dotted paper,
/// and the shared side, on smooth paper in a reading serif. The folded corner
/// shows the paper of the other face and is how the sheet is turned over.
///
/// Each action sits on what it touches: read on the source band, turn over on
/// the sheet's corner, write in the panel at the bottom — a note when the
/// member's side is up, the piece and its publication when the shared side is.
///
/// An article opens on its summary instead of the sheet — the essence, and
/// behind "See more…" the long one, read in the article's place. The sheet —
/// the fiche and its other face — is a screen of its own then, reached from
/// the source band beside "Read" (`asFiche`).
struct EntryView: View {
    /// Garden owner — the default repo/vault name for the editor links.
    let username: String
    /// Whether the member has a public site to publish to. Without one the
    /// shared side is written and kept as a draft; there is nothing to publish to.
    var hasSite = true
    /// The fiche of an article, opened from its page: the sheet alone.
    var asFiche = false

    /// The entry as it now reads: a write answers with it, and a book of the
    /// library becomes a garden entry the first time something is written.
    @State private var entry: ShelfEntry
    @State private var detail: EntryDetail?
    @State private var composing = false
    /// A note of the member's side opened to be rewritten, or to be taken off.
    @State private var noteEditing: NoteEditTarget?
    @State private var noteDeleting: NoteEditTarget?
    @State private var editing = false
    /// Who the entry is shared with: adding someone, taking someone off.
    @State private var sharing = false
    @State private var linkingBook = false
    /// Talking to Maurice from this entry.
    @State private var asking = false
    /// A past conversation, opened from the link a kept note carries.
    @State private var past: PastConversation?
    @State private var confirmPublish = false
    @State private var confirmUnpublish = false
    @State private var confirmDelete = false
    @State private var working = false
    @State private var writeError: String?
    /// An archive or a delete the server refused.
    @State private var actionError: String?
    @State private var deploy: DeployState?
    /// Which way the last publish went, while its deploy is still spoken of:
    /// "published" is said at once, "online" only when the site has it.
    @State private var lastPublish: Bool?
    /// The deploy has just landed: said for a few seconds, then the address.
    @State private var landed = false
    @State private var loading: Bool
    @State private var error: String?
    @State private var face: Face
    @State private var angle: Double = 0
    /// The conversations with Maurice about this entry, for its fiche.
    @State private var conversations: [EntryConversation] = []
    /// The article's summary as the page shows it, and its rewriting.
    @State private var summary: ShelfSource.Summary?
    @State private var summarizing = false
    @State private var summaryError: String?
    /// "See more…": the long summary in place of the paragraph.
    @State private var summaryOpen = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(CarnetSession.self) private var session

    init(entry: ShelfEntry, username: String, hasSite: Bool = true, asFiche: Bool = false) {
        self.username = username
        self.hasSite = hasSite
        self.asFiche = asFiche
        _entry = State(initialValue: entry)
        // An entry with nothing on the member's side opens on what it has.
        _face = State(initialValue: entry.mine == nil && entry.shared != nil ? .shared : .mine)
        _loading = State(initialValue: !entry.isLibraryOnly)
        // The shelf carries the summaries: the page opens on them, offline too.
        _summary = State(initialValue: entry.source?.summary)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                identity
                if !entry.translations.isEmpty { translations }
                if isArticlePage {
                    if let source = entry.source { band(source) }
                    summaryCard
                } else {
                    if !asFiche, let source = entry.source { band(source) }
                    sheet
                }
                if !asFiche { putAway }
            }
            .padding(.bottom, 24)
        }
        .gridTopChrome {
            GridChromeRow {
                GridBackButton(size: 40) { dismiss() }
            } trailing: {
                // Who writes here, then the way to add someone, then ⋯ — the
                // same order as a shared conversation's bar in the Maurice app.
                if entry.isShared {
                    Button { sharing = true } label: { AvatarStack(people: entry.people).padding(.horizontal, 6) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("entry.share.shared_with", entry.people.map(\.displayName).joined(separator: ", ")))
                }
                // The owner's to do; a book of the library with no entry has
                // nothing to share yet.
                if !entry.isForeign, !entry.isLibraryOnly {
                    Button { sharing = true } label: { GridIconGlyph(systemName: "person.badge.plus", size: 40) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("entry.share.button"))
                }
                // The card, to the system's share sheet: only while it is
                // the face shown and has something written, and once it is
                // published — a draft is not yet meant to go out, unless the
                // member has nowhere to publish to. Never the fiche.
                if !isArticlePage, face == .shared, let card = detail?.shared, CardText.hasText(card),
                   card.state == .published || !hasSite {
                    EntryShareButton(entry: entry, card: card)
                }
                // What ⋯ offers acts on the owner's files.
                if !entry.isForeign { moreMenu }
            }
        }
        .sheet(isPresented: $linkingBook) {
            LinkBookSheet(entry: entry) { apply($0) }
        }
        .sheet(isPresented: $sharing) {
            EntryShareSheet(entry: entry, me: session.activeMemberId) { written in
                if let written { apply(written) } else { dismiss() }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Group {
                switch isArticlePage ? .mine : face {
                case .mine: notePanel
                case .shared: sharedPanel
                }
            }
            .glassFooter()
        }
        .background(CarnetTheme.bg)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .sheet(isPresented: $composing) {
            NoteSheet(title: entry.title, offersPage: entry.source == nil, locale: writingLocale) { text, quote, page in
                apply(try await GardenAPI.addNote(to: entry, text: text, quote: quote, page: page))
            }
        }
        .noteEditing($noteEditing, deleting: $noteDeleting) { await load() }
        .fullScreenCover(isPresented: $editing) {
            SharedEditor(entryTitle: entry.title, title: detail?.shared?.title ?? "",
                         text: detail?.shared.map { SharedBody.withoutTitle($0.body, title: $0.title) } ?? "",
                         locale: writingLocale) { title, body in
                // A card already online is deployed again by the server: that
                // is an update of the site, not a publish one way or the other.
                lastPublish = nil
                apply(try await GardenAPI.writeShared(entry, body: body, title: title))
            }
        }
        // In the Maurice app — or, without it, in Carnet's own thread; what
        // was kept there is on the entry now: read it again on the way back.
        .mauriceHandoff(entry: entry, trigger: $asking) { kept in if kept { Task { await load() } } }
        .fullScreenCover(item: $past) { AskMauriceView(conversationId: $0.id) }
        // A kept note ends on a link to the conversation it came from
        // (`maurice://conversations/<id>`): opened in the Maurice app, or read
        // here when it is not on the device.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "maurice", url.host == "conversations",
                  let id = url.pathComponents.last, id != "/" else { return .systemAction }
            if MauriceApp.installed { return .systemAction }
            past = PastConversation(id: id)
            return .handled
        })
        // The panel that shows a write's error belongs to the shared side; on
        // the member's side a refresh that found nothing would say nothing.
        .alert(L("entry.nothing_to_add"), isPresented: Binding(get: { writeError != nil && face == .mine }, set: { if !$0 { writeError = nil } })) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(writeError ?? "")
        }
        .confirmationDialog(L("entry.publish.confirm"), isPresented: $confirmPublish, titleVisibility: .visible) {
            Button(L("entry.publish")) { publish(true) }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("entry.publish.confirm_hint"))
        }
        .alert(L("entry.action_failed"), isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .confirmationDialog(L("entry.delete.confirm", entry.title), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("entry.delete"), role: .destructive) { deleteEntry() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(Self.deleteWarning(entry))
        }
        .confirmationDialog(L("entry.unpublish.confirm"), isPresented: $confirmUnpublish, titleVisibility: .visible) {
            Button(L("entry.menu.unpublish"), role: .destructive) { publish(false) }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("entry.unpublish.confirm_hint"))
        }
    }

    /// The language this entry is written in — what dictation listens for.
    private var writingLocale: Locale { Locale(identifier: entry.locale ?? Locale.current.identifier) }

    /// Take what a write answered with: the entry and both faces as they now read.
    private func apply(_ written: GardenAPI.Written) {
        entry = written.entry
        detail = written.detail
        loading = false
        error = nil
        if let d = written.deploy { deploy = d; watchDeploy() }
    }

    // MARK: - Identity

    private var identity: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverImage(shelf: entry, width: 68, height: entry.kind.squareCover ? 68 : 98)
                .clipShape(RoundedRectangle(cornerRadius: CarnetTheme.coverCornerRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title)
                    .font(CarnetTheme.display(24))
                    .foregroundStyle(CarnetTheme.ink)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.kindLine)
                    .font(CarnetTheme.sans(14))
                    .foregroundStyle(CarnetTheme.inkSoft)
                if let from = entry.source?.sharedBy {
                    Text(from.line)
                        .font(CarnetTheme.sans(13))
                        .foregroundStyle(CarnetTheme.inkSoft)
                }
                if let meta = identityMeta { GridLabel(meta).padding(.top, 2) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.top, 6)
        .padding(.bottom, 16)
    }

    /// "★★★★ · abandoned · 2026-08-23"
    private var identityMeta: String? {
        var parts: [String] = []
        if let r = entry.rating, r > 0 { parts.append(String(repeating: "★", count: min(r, 5))) }
        if let s = entry.status, !s.isEmpty { parts.append(s) }
        if !entry.date.isEmpty { parts.append(entry.date) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var translations: some View {
        HStack(spacing: 10) {
            ForEach(entry.translations, id: \.id) { t in
                HStack(spacing: 7) {
                    GridLabel("Also in \(t.locale)", size: 9.5)
                    if let s = t.shared { StateMark(state: s.state.mark) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.bottom, 14)
    }

    // MARK: - The source

    @ViewBuilder private func band(_ source: ShelfSource) -> some View {
        let shape = RoundedRectangle(cornerRadius: CarnetTheme.cardCornerRadius, style: .continuous)
        if source.isBook, let bookId = source.bookId {
            let p = source.progress
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    GridLabel("The book · \(source.chapters ?? 0) chapters", size: 9.5)
                    Spacer(minLength: 0)
                    NavigationLink(value: bookStub(bookId)) {
                        HStack(spacing: 3) {
                            Text("Chapters").font(CarnetTheme.sans(13, weight: .medium))
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(CarnetTheme.ink)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(p?.chapterTitle ?? (p == nil ? "Not started" : "In progress"))
                            .font(CarnetTheme.sans(14.5, weight: .medium))
                            .foregroundStyle(CarnetTheme.ink)
                            .lineLimit(1)
                        GridBar(value: p?.fraction ?? 0, accentWhenFull: false)
                    }
                    NavigationLink(value: ShelfRoute.resume(bookId: bookId, title: entry.title, byline: entry.byline)) {
                        PrimaryLabel(title: p == nil ? "Read" : "Resume", systemImage: "book")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(CarnetTheme.surfaceAlt, in: shape)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        } else if source.captured ?? false, let slug = entry.slug, let locale = entry.locale {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    GridLabel("Captured page · \(source.wordCount ?? 0) words", size: 9.5)
                    Spacer(minLength: 0)
                    if let url = source.url.flatMap(URL.init(string:)) {
                        Button { openURL(url) } label: {
                            HStack(spacing: 3) {
                                Text("Original").font(CarnetTheme.sans(13, weight: .medium))
                                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(CarnetTheme.ink)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 10) {
                    Text("\(source.readingMinutes ?? 1) min")
                        .font(CarnetTheme.sans(14.5, weight: .medium))
                        .foregroundStyle(CarnetTheme.ink)
                    Spacer(minLength: 0)
                    if isArticlePage { ficheLink }
                    NavigationLink(value: entry.owner != nil ? ShelfRoute.readShared(entry) : ShelfRoute.read(slug: slug, locale: locale)) {
                        PrimaryLabel(title: "Read", systemImage: "book")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(CarnetTheme.surfaceAlt, in: shape)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        } else {
            // A bookmark: the source fails without drama.
            HStack(spacing: 12) {
                Text("The site refused the capture. Only the link was kept.")
                    .font(CarnetTheme.sans(13))
                    .foregroundStyle(CarnetTheme.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let url = source.url.flatMap(URL.init(string:)) {
                    GridButton(title: "Open", systemImage: "arrow.up.right", small: true) { openURL(url) }
                }
                if isArticlePage { ficheLink }
            }
            .padding(14)
            .overlay(shape.strokeBorder(CarnetTheme.ruleHard, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    /// Enough of a book for its page to load the rest.
    private func bookStub(_ id: Int) -> Book {
        Book(id: id, title: entry.title, authors: entry.byline.map { [$0] } ?? [], tags: nil, formats: nil,
             series: nil, description: nil, chapters: entry.source?.chapters, summarized: nil, indexed: nil, added: nil)
    }

    // MARK: - An article's page

    /// An article opens on its summary; its fiche is a screen of its own.
    private var isArticlePage: Bool { entry.kind == .articles && !asFiche }

    /// The way to the fiche, beside "Read": the dotted paper it opens on, and
    /// how much is written there.
    private var ficheLink: some View {
        NavigationLink(value: ShelfRoute.fiche(entry)) {
            HStack(spacing: 7) {
                Image(systemName: "note.text").font(.system(size: 13))
                Text(ficheCount > 0 ? "Fiche · \(ficheCount)" : "Fiche").font(CarnetTheme.sans(14, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .foregroundStyle(CarnetTheme.ink)
            .paper(.mine, in: Capsule())
            .overlay(Capsule().strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ficheCount > 0 ? "Fiche, \(ficheCount) items" : "Fiche")
    }

    /// Notes, highlights and the conversations held about it.
    private var ficheCount: Int { entry.noteCount + conversations.count }

    /// The page's body: the essence in a paragraph, then — "See more…" — the
    /// long summary, meant to be read instead of the article.
    private var summaryCard: some View {
        let shape = RoundedRectangle(cornerRadius: CarnetTheme.cardCornerRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                GridLabel("Summary", size: 9.5)
                if summarizing {
                    ProgressView().controlSize(.mini).tint(CarnetTheme.inkMute)
                    GridLabel("· Maurice is reading the article", size: 9.5)
                }
                Spacer(minLength: 0)
                // A summary that came out wrong — cut short, off the point —
                // is written again, both of them, from the article's text.
                if summary != nil, !summarizing, !entry.isForeign, entry.source?.captured ?? false {
                    Button { Task { await summarize(force: true) } } label: {
                        Label("Rewrite", systemImage: "arrow.clockwise")
                            .font(CarnetTheme.sans(12, weight: .medium))
                            .foregroundStyle(CarnetTheme.inkSoft)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rewrite the summary")
                }
            }
            if loading, summary == nil {
                ProgressView().tint(CarnetTheme.inkMute).frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if let summary, let shown = shownSummary(summary) {
                MarkdownBlocks(text: shown, serif: true)
                    .opacity(summarizing ? 0.55 : 1)
                if !summaryOpen, hasLong(summary), !summary.text.isEmpty {
                    Button { withAnimation(.easeOut(duration: 0.2)) { summaryOpen = true } } label: {
                        Text("See more…")
                            .font(CarnetTheme.sans(14, weight: .medium))
                            .foregroundStyle(CarnetTheme.ink)
                            .underline(true, color: CarnetTheme.ruleHard)
                    }
                    .buttonStyle(.plain)
                } else if summaryOpen {
                    Button { withAnimation(.easeOut(duration: 0.2)) { summaryOpen = false } } label: {
                        Text("See less")
                            .font(CarnetTheme.sans(14, weight: .medium))
                            .foregroundStyle(CarnetTheme.inkSoft)
                    }
                    .buttonStyle(.plain)
                }
            } else if entry.source?.captured ?? false {
                if !summarizing {
                    Text("No summary yet.").font(CarnetTheme.sans(14)).foregroundStyle(CarnetTheme.inkSoft)
                }
            } else {
                Text("The site refused the capture, so there is nothing to summarise. The original is still a tap away.")
                    .font(CarnetTheme.sans(13.5)).foregroundStyle(CarnetTheme.inkSoft)
            }
            if let summaryError {
                HStack(spacing: 10) {
                    Text(summaryError).font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    GridButton(title: "Try again", small: true) { Task { await summarize() } }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(CarnetTheme.surface, in: shape)
        .overlay(shape.strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
        .padding(.horizontal, 14)
    }

    private func hasLong(_ s: ShelfSource.Summary) -> Bool {
        !(s.long ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The paragraph first; the long summary once "See more…" is tapped — or
    /// alone, while the paragraph is still being written.
    private func shownSummary(_ s: ShelfSource.Summary) -> String? {
        if (summaryOpen || s.text.isEmpty), hasLong(s) { return s.long }
        return s.text.isEmpty ? nil : s.text
    }

    /// Ask for the summaries when one is missing or of an older kind. The
    /// server waits on a pass already running (just after the share) rather
    /// than starting a second one.
    private func summarize(force: Bool = false) async {
        guard let slug = entry.slug, let locale = entry.locale, !entry.isForeign,
              entry.source?.captured ?? false, !summarizing else { return }
        summarizing = true
        summaryError = nil
        defer { summarizing = false }
        do {
            summary = try await GardenAPI.summaries(slug: slug, locale: locale, force: force)
        } catch {
            if error.isCancellation { return }
            summaryError = "The summary could not be written. \(Self.message(error))"
        }
    }

    // MARK: - The sheet

    private var back: BackPaper {
        switch face {
        case .mine: return entry.shared == nil ? .blank : .shared
        case .shared: return entry.mine == nil ? .blank : .mine
        }
    }

    private var sheet: some View {
        let shape = SheetShape()
        return VStack(alignment: .leading, spacing: 14) {
            switch face {
            case .mine: mineFace
            case .shared: sharedFace
            }
            Spacer(minLength: 46)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 380, alignment: .topLeading)
        .paper(face, in: shape)
        .overlay(shape.strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
        // The other face is the owner's card: theirs to write, not shared here.
        .overlay(alignment: .bottomTrailing) { if !entry.isForeign { corner } }
        .padding(.horizontal, 14)
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
    }

    /// The folded corner: the other face's paper, and the one place to turn over.
    private var corner: some View {
        Button(action: turnOver) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Turn over").font(CarnetTheme.sans(13, weight: .semibold)).foregroundStyle(CarnetTheme.ink)
                    backLabel
                }
                .padding(.bottom, 8)
                FoldedCorner(back: back)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Turn over")
    }

    @ViewBuilder private var backLabel: some View {
        switch face {
        case .mine:
            if let s = entry.shared { StateMark(state: s.state.mark) }
            else { GridLabel("Blank", size: 9.5) }
        case .shared:
            if entry.mine != nil {
                GridLabel("\(entry.noteCount) \(entry.noteCount == 1 ? "note" : "notes")", size: 9.5)
            } else { GridLabel("Blank", size: 9.5) }
        }
    }

    private func turnOver() {
        withAnimation(.easeIn(duration: 0.16)) { angle = 90 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            face = face == .mine ? .shared : .mine
            angle = -90
            withAnimation(.easeOut(duration: 0.2)) { angle = 0 }
        }
    }

    // MARK: - My side

    /// Who reads this side: "Only you", or the people it is shared with.
    private var audience: String {
        if let owner = entry.owner { return L("article.shared_by", owner.displayName) }
        let names = (entry.participants ?? []).map(\.displayName)
        return names.isEmpty ? L("entry.audience.only_you") : L("entry.audience.you_and", names.joined(separator: ", "))
    }

    @ViewBuilder private var mineFace: some View {
        HStack(spacing: 5) {
            Image(systemName: entry.isShared ? "person.2.fill" : "lock.fill")
                .font(.system(size: 8)).foregroundStyle(CarnetTheme.inkMute)
            GridLabel(entry.noteCount > 0 ? "\(audience) · \(entry.noteCount) \(entry.noteCount == 1 ? "note" : "notes")"
                                          : audience, size: 9.5).lineLimit(1)
        }
        if loading {
            ProgressView().tint(CarnetTheme.inkMute).frame(maxWidth: .infinity).padding(.top, 40)
        } else if let error {
            Text(error).font(CarnetTheme.sans(13)).foregroundStyle(CarnetTheme.inkSoft)
        } else if let mine = detail?.mine, !(mine.prose.isEmpty && mine.items.isEmpty) || !conversations.isEmpty {
            if !mine.prose.isEmpty { MarkdownBlocks(text: mine.prose, serif: false) }
            ForEach(mine.items) { item in
                MineItemView(item: item, signed: entry.isShared)
                    .noteActions(item, onEdit: { noteEditing = NoteEditTarget(entry: entry, item: item) },
                                 onDelete: { noteDeleting = NoteEditTarget(entry: entry, item: item) })
            }
            if !conversations.isEmpty { EntryConversationsSection(entry: entry, conversations: conversations) }
        } else if detail?.mine == nil, !conversations.isEmpty {
            EntryConversationsSection(entry: entry, conversations: conversations)
        } else {
            VStack(spacing: 6) {
                Text("Nothing here yet.").font(CarnetTheme.sans(14)).foregroundStyle(CarnetTheme.inkSoft)
                Text(entry.source?.isReadable == true ? "Highlight while reading, and it lands here."
                                                      : "Your notes on this will be kept here.")
                    .font(CarnetTheme.sans(13)).foregroundStyle(CarnetTheme.inkMute)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 70)
        }
    }

    // MARK: - Shared side

    @ViewBuilder private var sharedFace: some View {
        if let state = entry.shared?.state {
            HStack(spacing: 7) {
                StateMark(state: state.mark)
                if state == .draft { GridLabel("· not on your site", size: 9.5) }
            }
        } else {
            GridLabel("To share", size: 9.5)
        }
        if loading {
            ProgressView().tint(CarnetTheme.inkMute).frame(maxWidth: .infinity).padding(.top, 40)
        } else if let shared = detail?.shared {
            if let title = shared.title {
                Text(title).font(CarnetTheme.display(22)).foregroundStyle(CarnetTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            MarkdownBlocks(text: SharedBody.withoutTitle(shared.body, title: shared.title), serif: true, links: shared.links)
        } else {
            VStack(spacing: 6) {
                Text("Nothing written yet.").font(CarnetTheme.sans(14)).foregroundStyle(CarnetTheme.inkSoft)
                Text("This side is for what you would say about it to someone else.")
                    .font(CarnetTheme.sans(13)).foregroundStyle(CarnetTheme.inkMute)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 70)
        }
    }

    // MARK: - The panel: writing

    /// My side up: the one thing to do is add to it. The same dotted paper as
    /// the sheet, since it is where the member writes for themself.
    private var notePanel: some View {
        // A book of the library nothing is written on is not an entry yet —
        // a first note makes it one. Nor is someone else's entry one Maurice
        // can be asked from yet: what he keeps of an exchange goes to the
        // asker's own garden.
        WritePanel(onNote: { composing = true },
                   onAsk: entry.isLibraryOnly || entry.isForeign ? nil : { asking = true })
    }

    /// Shared side up: edit, where it is (or will be), and the one primary
    /// action — write when it is blank, publish when it is a draft.
    @ViewBuilder private var sharedPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let writeError {
                Text(writeError).font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkSoft)
                    .padding(.horizontal, 6)
            }
            HStack(spacing: 10) {
                if let shared = detail?.shared {
                    Button { editing = true } label: {
                        Image(systemName: "pencil").font(.system(size: 16)).gridControlChrome(size: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit")
                    Text(panelLine(shared))
                        .font(CarnetTheme.mono(11))
                        .foregroundStyle(CarnetTheme.inkSoft)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if working || (deploy?.inProgress ?? false) {
                        ProgressView().tint(CarnetTheme.inkMute).padding(.trailing, 8)
                    } else if landed {
                        Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(CarnetTheme.inkSoft).padding(.trailing, 10)
                    } else if shared.state == .draft, hasSite {
                        GridButton(title: "Publish", systemImage: "globe", primary: true, small: true) {
                            confirmPublish = true
                        }
                    } else {
                        // Online: take it off, beside going to see it. The
                        // line is narrow, so the first says it with its icon.
                        if shared.state == .published, hasSite {
                            Button { confirmUnpublish = true } label: {
                                Image(systemName: "eye.slash").font(.system(size: 15)).gridControlChrome(size: 40)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L("entry.menu.unpublish"))
                        }
                        if let url = shared.publicUrl.flatMap(URL.init(string:)) {
                            GridButton(title: "Open", systemImage: "arrow.up.right", small: true) { openURL(url) }
                        }
                    }
                } else {
                    Text(entry.isLibraryOnly ? "Add a note first: it makes this an entry." : "Nothing written yet")
                        .font(CarnetTheme.sans(13.5))
                        .foregroundStyle(CarnetTheme.inkMute)
                        .padding(.leading, 8)
                    Spacer(minLength: 0)
                    if !entry.isLibraryOnly {
                        GridButton(title: "Write", systemImage: "pencil", primary: true, small: true) { editing = true }
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 12)
    }

    private func panelLine(_ shared: EntryDetail.Shared) -> String {
        // Two different things, said apart: the entry is published the moment
        // the server has answered, and online once the site carries it.
        if deploy?.inProgress ?? false {
            switch lastPublish {
            case true?: return "Published · going online…"
            case false?: return "Unpublished · going offline…"
            case nil: return "Updating your site…"
            }
        }
        if deploy?.failed ?? false {
            switch lastPublish {
            case true?: return "Published, but not online"
            case false?: return "Unpublished, but still online"
            case nil: return "The site did not update"
            }
        }
        if landed { return lastPublish == false ? "Offline" : "Online" }
        if let u = shared.publicUrl { return u.replacingOccurrences(of: "https://", with: "") }
        return shared.state == .published ? "Published" : "Draft"
    }

    private func publish(_ on: Bool) {
        working = true
        writeError = nil
        landed = false
        Task {
            do {
                let written = try await GardenAPI.setPublished(entry, on)
                lastPublish = on
                apply(written)
            }
            catch { writeError = Self.message(error) }
            working = false
        }
    }

    /// The page behind an entry that shows without a picture: an article the
    /// server could not fetch one for.
    private var missingCoverURL: URL? {
        guard entry.image == nil, let raw = entry.source?.url, let url = URL(string: raw),
              url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    /// The same request for every entry. The page's own picture first, read
    /// here by the system's link preview, for one that has none and has a
    /// page; then the server completes what it can from what the garden holds
    /// — a cover the provider named, the fields of its kind on the card.
    private func refreshDetails() {
        working = true
        writeError = nil
        Task {
            do {
                if let url = missingCoverURL, let jpeg = await LinkCover.fetch(url).jpeg {
                    apply(try await GardenAPI.setCover(entry, jpeg: jpeg))
                }
                apply(try await GardenAPI.refreshDetails(entry))
                if entry.image == nil { writeError = "No picture could be found for this one." }
            }
            catch { writeError = Self.message(error) }
            working = false
        }
    }

    /// The site takes a few seconds to carry a publish: ask until it does,
    /// say so for a moment, then leave the address in its place.
    private func watchDeploy() {
        Task {
            while deploy?.inProgress ?? false {
                try? await Task.sleep(for: .seconds(2))
                if let d = try? await GardenAPI.deployState() { deploy = d }
            }
            guard lastPublish != nil, !(deploy?.failed ?? false) else { return }
            landed = true
            try? await Task.sleep(for: .seconds(4))
            landed = false
        }
    }

    // MARK: - Putting it away

    /// Most of the time the summary is all one reads of a thing: the page
    /// ends on what to do with it then — put it away from the list, or delete
    /// it. Archiving is the member's own and changes nothing in the garden;
    /// another member's entry, or a book of the library with no entry, has
    /// nothing of this member's to delete.
    private var putAway: some View {
        let archived = entry.archived ?? false
        return HStack(spacing: 12) {
            GridButton(title: L(archived ? "entry.unarchive" : "entry.archive"),
                       systemImage: archived ? "tray.and.arrow.up" : "archivebox") {
                setArchived(!archived)
            }
            if !entry.isLibraryOnly, !entry.isForeign {
                GridButton(title: L("entry.delete"), systemImage: "trash", destructive: true) {
                    confirmDelete = true
                }
            }
        }
        .disabled(working)
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.horizontal, 20)
    }

    /// Done, the page has nothing left to show: back to the list, which reads
    /// itself again as it reappears. Refused, the page stays and says why.
    private func setArchived(_ on: Bool) {
        working = true
        Task {
            defer { working = false }
            do {
                try await GardenAPI.setArchived(entry, on)
                dismiss()
            } catch { actionError = Self.message(error) }
        }
    }

    private func deleteEntry() {
        working = true
        Task {
            defer { working = false }
            do {
                try await GardenAPI.deleteEntry(entry)
                dismiss()
            } catch { actionError = Self.message(error) }
        }
    }

    /// What a delete takes with it, said before it is confirmed — here and on
    /// the list's swipe.
    static func deleteWarning(_ entry: ShelfEntry) -> String {
        var lines = [L("entry.delete.notes")]
        let online = entry.shared?.state == .published || entry.translations.contains { $0.shared?.state == .published }
        if online { lines.append(L("entry.delete.online")) }
        if entry.source?.isBook ?? false { lines.append(L("entry.delete.book")) }
        return lines.joined(separator: " ")
    }

    /// What the server said went wrong, without its JSON wrapping.
    static func message(_ error: Error) -> String {
        let raw = error.localizedDescription
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = obj["error"] as? String { return msg }
        return raw
    }

    // MARK: - ⋯ (where the files live)

    @ViewBuilder private var moreMenu: some View {
        // The face that is up, or the other when this one has no file: an
        // entry with a card and no fiche — a podcast, an article kept as a
        // link — opens on a side that holds nothing, and its menu had nothing
        // to offer and did not open at all.
        let file = (face == .mine ? detail?.mine?.file : detail?.shared?.file) ?? detail?.shared?.file ?? detail?.mine?.file
        let web = (face == .mine ? detail?.mine?.webPath : detail?.shared?.webPath) ?? detail?.shared?.webPath ?? detail?.mine?.webPath
        Menu {
            // Whichever face is up: a published entry can be taken off from either.
            if detail?.shared?.state == .published, hasSite {
                Button(role: .destructive) { confirmUnpublish = true } label: { Label(L("entry.menu.unpublish"), systemImage: "eye.slash") }
            }
            // The cover, the author, the platform: taken again from what the
            // fiche knows, for a card that shows without them.
            // The same for every kind of entry: whatever it lacks that can be
            // found again — its cover, the fields of its kind.
            Button { refreshDetails() } label: { Label(L("entry.menu.refresh"), systemImage: "arrow.clockwise") }
            // A book: the library's copy it is about, when the title did not
            // find it, or found the wrong one.
            if entry.collection == "books" {
                Button { linkingBook = true } label: {
                    Label(L(entry.source?.isBook == true ? "entry.menu.change_book" : "entry.menu.link_book"), systemImage: "books.vertical")
                }
            }
            if let web {
                Button {
                    Task { if let url = await GardenLinks.webURL(web) { openURL(url) } }
                } label: { Label(L("entry.menu.browser"), systemImage: "safari") }
            }
            if let file {
                if let url = GardenLinks.workingCopyURL(file: file, username: username) {
                    Button { openURL(url) } label: { Label(L("entry.menu.working_copy"), systemImage: "square.and.pencil") }
                }
                if let url = GardenLinks.obsidianURL(file: file, username: username) {
                    Button { openURL(url) } label: { Label(L("entry.menu.obsidian"), systemImage: "diamond") }
                    Button { UIPasteboard.general.string = url.absoluteString } label: {
                        Label(L("entry.menu.obsidian_link"), systemImage: "doc.on.doc")
                    }
                }
            }
        } label: {
            if working {
                ProgressView().tint(CarnetTheme.inkMute).frame(width: 40, height: 40)
            } else {
                GridIconGlyph(systemName: "ellipsis", size: 40)
            }
        }
        // A book of the library with no entry has no page: nothing to act on.
        .disabled(entry.isLibraryOnly || working)
        .accessibilityLabel(L("entry.menu.more"))
    }

    // MARK: - Loading

    private func load() async {
        // Read again each time the page appears: coming back from the reader,
        // a note or a highlight made there is on it.
        guard !entry.isLibraryOnly else { return }
        do {
            // The row with the page: who it is shared with may have changed
            // since the list was read.
            async let talks = GardenAPI.conversations(about: entry)
            if let page = try await GardenAPI.entryPage(entry) {
                entry = page.entry
                detail = page.detail
                // A page without a summary does not take away the one kept here.
                if !summarizing, let fresh = page.entry.source?.summary { summary = fresh }
            }
            conversations = (try? await talks) ?? conversations
            error = nil
        } catch {
            if error.isCancellation { return }
            self.error = "Couldn't load this entry.\n\(error.localizedDescription)"
        }
        loading = false
        // An article whose summaries are missing or of an older kind: written
        // now, while the page shows what there is.
        if isArticlePage, !(summary?.current ?? false) { await summarize() }
    }
}

// MARK: - Writing a note

/// A note for the member's side: what they think, and optionally the passage
/// it is about. Written on the same dotted paper it will land on.
struct NoteSheet: View {
    let title: String
    /// A page number makes sense for what was read elsewhere, on paper.
    var offersPage = false
    /// The chapter being read, when the note is taken from the reader.
    var chapterTitle: String? = nil
    /// The language the note is written in — what dictation listens for.
    var locale: Locale = .current
    /// A note already written, opened to be rewritten: the sheet starts from
    /// it, and « Save » replaces it (`NoteEditing.swift`).
    var editing: MineItem? = nil
    /// Offered on a note being rewritten that the member may take off.
    var onDelete: (() async throws -> Void)? = nil
    var onKeep: (_ text: String, _ quote: String?, _ page: String?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var quote = ""
    @State private var page = ""
    @State private var quoting = false
    @State private var sending = false
    @State private var error: String?
    @State private var prefilled = false
    @State private var confirmDelete = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedQuote: String { quote.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var paperShape: RoundedRectangle { RoundedRectangle(cornerRadius: CarnetTheme.cardCornerRadius, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(CarnetTheme.inkMute)
                GridLabel(L("note.sheet.goes_on_your_side", chapterTitle ?? title), size: 9.5)
                    .lineLimit(1)
                Spacer(minLength: 0)
                DictationMic(text: $text, locale: locale)
                Button { quoting.toggle() } label: {
                    Image(systemName: "quote.opening").font(.system(size: 14))
                        .gridControlChrome(size: 34, on: quoting)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("note.sheet.add_quote"))
            }

            VStack(alignment: .leading, spacing: 8) {
                if quoting {
                    TextField(L("note.sheet.passage"), text: $quote, axis: .vertical)
                        .font(CarnetTheme.sans(14.5))
                        .lineLimit(1...5)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(CarnetTheme.inkWash, in: RoundedRectangle(cornerRadius: 3))
                    if offersPage {
                        TextField(L("note.sheet.page"), text: $page)
                            .font(CarnetTheme.mono(12))
                            .keyboardType(.numbersAndPunctuation)
                            .frame(width: 90)
                    }
                }
                TextEditor(text: $text)
                    .font(CarnetTheme.sans(15.5))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 110)
                    .focused($focused)
            }
            .padding(10)
            .paper(.mine, in: paperShape)
            .overlay(paperShape.strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))

            if let error {
                Text(error).font(CarnetTheme.caption).foregroundStyle(CarnetTheme.inkSoft)
            }

            HStack {
                GridButton(title: L("common.cancel"), small: true) { dismiss() }
                Spacer()
                if editing != nil {
                    GridButton(title: sending ? L("note.edit.saving") : L("note.edit.save"), systemImage: "checkmark",
                               primary: true, small: true) {
                        Task { await keep() }
                    }
                    .disabled(sending || (trimmed.isEmpty && trimmedQuote.isEmpty))
                } else {
                    GridButton(title: sending ? L("note.sheet.keeping") : L("note.sheet.keep"), systemImage: "checkmark", primary: true, small: true) {
                        Task { await keep() }
                    }
                    .disabled(sending || (trimmed.isEmpty && trimmedQuote.isEmpty))
                }
            }

            if editing != nil, onDelete != nil {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(L("note.edit.delete"), systemImage: "trash")
                        .font(CarnetTheme.sans(13.5, weight: .medium))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassSheetBackground()
        .presentationDetents([.medium, .large])
        .onAppear {
            if let item = editing, !prefilled {
                prefilled = true
                text = item.text ?? ""
                quote = item.quote ?? ""
                page = item.place?.page ?? ""
                quoting = !quote.isEmpty || !page.isEmpty
            }
            focused = true
        }
        .confirmationDialog(L("note.edit.delete_confirm"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("note.edit.delete"), role: .destructive) { Task { await delete() } }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("note.edit.delete_hint"))
        }
    }

    private func delete() async {
        guard let onDelete else { return }
        sending = true; error = nil
        do {
            try await onDelete()
            dismiss()
        } catch {
            self.error = NoteEdits.message(error)
        }
        sending = false
    }

    private func keep() async {
        sending = true; error = nil
        do {
            try await onKeep(trimmed, quoting && !trimmedQuote.isEmpty ? trimmedQuote : nil,
                             quoting && !page.trimmingCharacters(in: .whitespaces).isEmpty ? page : nil)
            dismiss()
        } catch {
            self.error = editing == nil ? EntryView.message(error) : NoteEdits.message(error)
        }
        sending = false
    }
}

// MARK: - Writing the shared side

/// The piece the member writes to be read: a title, optional, and the text.
/// Smooth paper and a reading serif, as it will be read.
struct SharedEditor: View {
    let entryTitle: String
    @State var title: String
    @State var text: String
    /// The language the piece is written in — what dictation listens for.
    var locale: Locale = .current
    var onSave: (_ title: String?, _ body: String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                GridButton(title: "Cancel", small: true) { dismiss() }
                Spacer()
                GridLabel("Draft · \(entryTitle)", size: 9.5).lineLimit(1)
                Spacer()
                DictationMic(text: $text, locale: locale)
                GridButton(title: saving ? "Saving…" : "Save", primary: true, small: true) { Task { await save() } }
                    .disabled(saving)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if let error {
                Text(error).font(CarnetTheme.caption).foregroundStyle(CarnetTheme.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 6)
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField("Title, if it has one", text: $title, axis: .vertical)
                    .font(CarnetTheme.display(22))
                    .foregroundStyle(CarnetTheme.ink)
                TextEditor(text: $text)
                    .font(.system(size: 17, design: .serif))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CarnetTheme.surface,
                        in: RoundedRectangle(cornerRadius: CarnetTheme.cardCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CarnetTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .background(CarnetTheme.bg)
        .onAppear { focused = true }
    }

    private func save() async {
        saving = true; error = nil
        do {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            try await onSave(t.isEmpty ? nil : t, text.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch {
            self.error = EntryView.message(error)
        }
        saving = false
    }
}

// MARK: - The primary action, as a label (for navigation links)

struct PrimaryLabel: View {
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 13)) }
            Text(title).font(CarnetTheme.sans(14, weight: .semibold))
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .foregroundStyle(CarnetTheme.accentInk)
        .background(Capsule().fill(CarnetTheme.accent))
        .contentShape(Capsule())
    }
}

// MARK: - One item of my side

/// A conversation to read back, named by the link a kept note carries.
struct PastConversation: Identifiable, Hashable {
    let id: String
}

struct MineItemView: View {
    let item: MineItem
    /// On an entry several people write on: each item opens on who wrote it.
    var signed = false
    @Environment(\.openURL) private var openURL

    /// A note kept from a conversation ends on `*([Conversation avec Maurice :
    /// « … »](maurice://conversations/<id>))*`: read inline, it was a grey
    /// link nobody saw. It is taken off the text and shown as its own line,
    /// the way back to the conversation.
    private static let provenance = /\s*\*?\(\[([^\]]*)\]\((maurice:\/\/conversations\/[^)\s]+)\)\)\*?\s*$/

    private var backlink: (text: String, label: String, url: URL)? {
        guard let text = item.text, let m = text.firstMatch(of: Self.provenance),
              let url = URL(string: String(m.output.2)) else { return nil }
        return (String(text[..<m.range.lowerBound]), String(m.output.1), url)
    }

    /// A note as written, its inline marks read — a note kept from a
    /// conversation ends on a link back to it.
    static func inline(_ source: String) -> AttributedString {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: source, options: opts)) ?? AttributedString(source)
    }

    private var eyebrow: String {
        var parts: [String] = []
        switch item.kind {
        case "highlight":
            parts.append(item.place?.chapterTitle ?? "highlight")
            if item.place?.view == "summary" { parts.append("summary") }
        case "quote":
            parts.append(item.place?.page.map { "quote · p. \($0)" } ?? "quote")
        case "resonance":
            parts.append(item.from.map { "résonance → \($0.label)" } ?? "résonance")
        case "fragment":
            parts.append("from Maurice")
        default:
            parts.append("note")
        }
        if let date = item.date { parts.append(date) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if signed {
            HStack(alignment: .top, spacing: 10) {
                signature.padding(.top, 1)
                content
            }
        } else {
            content
        }
    }

    /// Who the item is owed to. A note kept from a conversation with Maurice
    /// is his mark, with whoever started the conversation over its corner;
    /// what Maurice filed himself is his mark alone.
    @ViewBuilder private var signature: some View {
        if let exchange = item.conversation {
            MauriceMark(size: 24)
                .overlay(alignment: .bottomTrailing) {
                    if let who = exchange.initiator ?? item.author {
                        MemberBadge(member: who.member, size: 14)
                            .overlay(Circle().strokeBorder(CarnetTheme.bg, lineWidth: 1.5))
                            .offset(x: 5, y: 5)
                    }
                }
                .accessibilityLabel("Maurice, asked by \((exchange.initiator ?? item.author)?.displayName ?? "someone")")
        } else if item.kind == "fragment" {
            MauriceMark(size: 24).accessibilityLabel("Maurice")
        } else if let author = item.author {
            MemberBadge(member: author.member, size: 24).accessibilityLabel(author.displayName)
        } else {
            Color.clear.frame(width: 24, height: 24)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                GridLabel(eyebrow, size: 9.5).lineLimit(1).layoutPriority(1)
                // Rewritten since: said after the date, quietly.
                if let edited = item.edited, !edited.isEmpty {
                    Text(NoteEdits.editedLine(edited))
                        .font(CarnetTheme.sans(11).italic())
                        .foregroundStyle(CarnetTheme.inkHint)
                        .lineLimit(1)
                }
            }
            if item.kind == "fragment" {
                if let summary = item.summary, !summary.isEmpty {
                    Text(summary).font(CarnetTheme.sans(14, weight: .medium)).foregroundStyle(CarnetTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                MarkdownBlocks(text: item.text ?? "", serif: false, lineLimit: 6)
            } else {
                if let quote = item.quote, !quote.isEmpty {
                    Text(quote)
                        .font(CarnetTheme.sans(14.5))
                        .foregroundStyle(CarnetTheme.ink)
                        .padding(.horizontal, 3)
                        .background(item.kind == "highlight" ? CarnetTheme.inkWash : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 2))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let text = backlink?.text ?? item.text, !text.isEmpty {
                    Text(Self.inline(text))
                        .font(CarnetTheme.sans(14))
                        .tint(CarnetTheme.inkSoft)
                        .foregroundStyle(item.quote?.isEmpty == false ? CarnetTheme.inkSoft : CarnetTheme.ink)
                        .padding(.leading, item.quote?.isEmpty == false ? 9 : 0)
                        .overlay(alignment: .leading) {
                            if item.quote?.isEmpty == false {
                                Rectangle().fill(CarnetTheme.ruleHard).frame(width: 1.5)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let link = backlink {
                    Button { openURL(link.url) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 11, weight: .medium))
                            Text(link.label)
                                .font(CarnetTheme.sans(12.5, weight: .medium))
                                .underline()
                                .multilineTextAlignment(.leading)
                        }
                        .foregroundStyle(CarnetTheme.inkSoft)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .accessibilityHint("Opens the conversation this note came from")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The panel: writing

/// What is at the bottom of an entry's page and of its reader: add a note,
/// or talk it over with Maurice and keep what comes of it. The same dotted
/// paper as the member's side, since it is where they write for themself.
struct WritePanel: View {
    var onNote: () -> Void
    /// Nil where Maurice cannot be asked from.
    var onAsk: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onNote) {
                HStack(spacing: 10) {
                    Text(L("note.panel.placeholder")).font(CarnetTheme.sans(15)).foregroundStyle(CarnetTheme.inkMute)
                    Spacer(minLength: 0)
                    Image(systemName: "quote.opening").font(.system(size: 13)).foregroundStyle(CarnetTheme.inkSoft)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .paper(.mine, in: Capsule())
                .overlay(Capsule().strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("note.panel.add"))

            if let onAsk {
                Button(action: onAsk) {
                    // Maurice's bowler hat — his own mark (the Maurice app's
                    // `maurice-logomark`, a template silhouette), the way the
                    // Maurice app marks Carnet with its pipe.
                    MauriceMark(size: 44).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("note.panel.ask_maurice"))
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Who writes here

/// Maurice's bowler hat in his colour, at the size of a member's badge.
struct MauriceMark: View {
    var size: CGFloat = 24

    var body: some View {
        Image("maurice-logomark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size * 0.56, height: size * 0.42)
            .foregroundStyle(CarnetTheme.accentInk)
            .frame(width: size, height: size)
            .background(Circle().fill(CarnetTheme.accent))
    }
}

/// The people on an entry, as overlapping badges — three at most, then a count.
struct AvatarStack: View {
    let people: [MemberBrief]
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(people.prefix(3)) { person in
                MemberBadge(member: person.member, size: size)
                    .overlay(Circle().strokeBorder(CarnetTheme.bg, lineWidth: 1.5))
            }
            if people.count > 3 {
                Text("+\(people.count - 3)")
                    .font(CarnetTheme.sans(size * 0.4, weight: .semibold))
                    .foregroundStyle(CarnetTheme.inkSoft)
                    .frame(width: size, height: size)
                    .background(Circle().fill(CarnetTheme.surface))
                    .overlay(Circle().strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
            }
        }
    }
}

/// Who an entry is shared with. The owner adds members of the household and
/// takes them off; a member it is shared with sees who is there and may take
/// themselves off. `onChange` is given the entry as it now reads — or nothing
/// when the reader has just left it.
struct EntryShareSheet: View {
    let entry: ShelfEntry
    let me: String?
    var onChange: (GardenAPI.Written?) -> Void

    @State private var current: ShelfEntry
    @State private var roster: [CarnetAPI.Member] = []
    @State private var rosterRead = false
    @State private var busy: String?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(entry: ShelfEntry, me: String?, onChange: @escaping (GardenAPI.Written?) -> Void) {
        self.entry = entry
        self.me = me
        self.onChange = onChange
        _current = State(initialValue: entry)
    }

    /// The household's members who are not on the entry yet.
    private var others: [CarnetAPI.Member] {
        let there = Set(current.people.map(\.id))
        return roster.filter { $0.id != me && !there.contains($0.id) && $0.id != current.owner?.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    GridLabel(L(current.isForeign ? "entry.share.with_you" : "entry.share.title"))
                    Text(current.title).font(CarnetTheme.display(20)).foregroundStyle(CarnetTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L(current.isForeign ? "entry.share.hint.reader" : "entry.share.hint.owner"))
                        .font(CarnetTheme.sans(13)).foregroundStyle(CarnetTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if current.isShared {
                    VStack(alignment: .leading, spacing: 0) {
                        GridLabel(L("entry.share.on_entry"), size: 9.5).padding(.bottom, 6)
                        if let owner = current.owner {
                            row(owner.member, note: L("entry.share.owner"))
                        }
                        ForEach(current.participants ?? []) { person in
                            row(person.member, note: person.id == me ? L("entry.share.you") : nil) {
                                // The owner takes anyone off; a member only themselves.
                                if !current.isForeign {
                                    action(L("entry.share.remove"), id: person.id) { try await remove(person.id) }
                                } else if person.id == me {
                                    action(L("entry.share.leave"), id: person.id) { try await leave() }
                                }
                            }
                        }
                    }
                }

                if !current.isForeign {
                    VStack(alignment: .leading, spacing: 0) {
                        GridLabel(L("entry.share.add_someone"), size: 9.5).padding(.bottom, 6)
                        // Nothing more to say when the roster could not be read:
                        // the error below says it.
                        if others.isEmpty, !(rosterRead && roster.isEmpty) {
                            Text(rosterRead ? L("entry.share.everyone_here") : L("give.section.loading"))
                                .font(CarnetTheme.sans(13)).foregroundStyle(CarnetTheme.inkMute)
                                .padding(.vertical, 10)
                        }
                        ForEach(others) { member in
                            row(member, note: nil) {
                                action(L("entry.share.add"), id: member.id, primary: true) { try await add(member.id) }
                            }
                        }
                    }
                }

                // Someone in another household of this device: the entry is
                // given to them, a copy chosen element by element.
                if !current.isForeign, !current.isLibraryOnly {
                    OtherHouseholdsSection(entry: current) { dismiss() }
                }

                if let error {
                    Text(error).font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkSoft)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .glassSheetBackground()
        .presentationDetents([.medium, .large])
        .task {
            // The roster is the household's; a failure leaves the list of
            // who is already here, which needs nothing from the network.
            roster = (try? await CarnetAPI.listMembers()) ?? []
            rosterRead = true
            if roster.isEmpty { error = L("entry.share.roster_failed") }
        }
    }

    private func row(_ member: CarnetAPI.Member, note: String?, @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 12) {
            MemberBadge(member: member, size: 30)
            Text(member.display_name).font(CarnetTheme.sans(15, weight: .medium)).foregroundStyle(CarnetTheme.ink)
            if let note { GridLabel(note, size: 9, color: CarnetTheme.inkMute) }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { GridRule() }
    }

    private func action(_ title: String, id: String, primary: Bool = false, _ work: @escaping () async throws -> Void) -> some View {
        Group {
            if busy == id {
                ProgressView().tint(CarnetTheme.inkMute).frame(height: 30)
            } else {
                GridButton(title: title, primary: primary, small: true) {
                    busy = id
                    error = nil
                    Task {
                        do { try await work() } catch { self.error = error.localizedDescription }
                        busy = nil
                    }
                }
            }
        }
        .disabled(busy != nil)
    }

    private func add(_ memberId: String) async throws {
        let written = try await GardenAPI.share(current, with: memberId)
        current = written.entry
        onChange(written)
    }

    private func remove(_ memberId: String) async throws {
        guard let written = try await GardenAPI.unshare(current, memberId: memberId) else { return }
        current = written.entry
        onChange(written)
    }

    private func leave() async throws {
        guard let me else { return }
        try await GardenAPI.unshare(current, memberId: me)
        dismiss()
        onChange(nil)
    }
}

// MARK: - Markdown, by blocks

enum SharedBody {
    /// The body without its own `# Title` line, which the page shows above it.
    static func withoutTitle(_ body: String, title: String?) -> String {
        guard title != nil else { return body }
        return body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("# ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Paragraphs, headings and quotes of a markdown text, with its inline marks.
/// `[[wiki-links]]` read as citations: underlined and tappable when the entry
/// they name has a published page, dotted when it is the member's alone.
struct MarkdownBlocks: View {
    let text: String
    let serif: Bool
    var links: [EntryDetail.Link] = []
    var lineLimit: Int? = nil

    private var blocks: [String] {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "---" }
    }

    private func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        serif ? .system(size: size + 1.5, weight: weight, design: .serif) : CarnetTheme.sans(size, weight: weight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: serif ? 13 : 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.hasPrefix("#") {
                    Text(inline(block.drop { $0 == "#" || $0 == " " }.description))
                        .font(body(14.5, weight: .semibold))
                        .foregroundStyle(CarnetTheme.ink)
                } else if block.hasPrefix(">") {
                    let quoted = block.split(separator: "\n").map { $0.drop { $0 == ">" || $0 == " " } }.joined(separator: "\n")
                    Text(inline(quoted))
                        .font(body(14.5))
                        .foregroundStyle(CarnetTheme.inkSoft)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(CarnetTheme.ruleHard).frame(width: 1.5) }
                } else {
                    // A paragraph wrapped by hand in the file is still one
                    // paragraph; list lines keep their breaks.
                    let listed = block.hasPrefix("- ") || block.hasPrefix("* ") || block.first?.isNumber == true
                    Text(inline(listed ? block : block.replacingOccurrences(of: "\n", with: " ")))
                        .font(body(14.5))
                        .lineSpacing(serif ? 4 : 2.5)
                        .foregroundStyle(CarnetTheme.ink)
                }
            }
        }
        .lineLimit(lineLimit)
        .tint(CarnetTheme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ source: String) -> AttributedString {
        // A citation becomes a markdown link first, so the inline parser keeps
        // its label; the scheme says which kind it is.
        var md = source
        let pattern = /\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/
        md = md.replacing(pattern) { m in
            let basename = String(m.1)
            let label = m.2.map(String.init) ?? basename
            let published = links.first { $0.basename == basename }?.publishedUrl
            return "[\(label)](\(published ?? "carnet-private://entry"))"
        }
        var out = (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(md)
        for run in out.runs {
            guard let url = run.link else { continue }
            if url.scheme == "carnet-private" {
                out[run.range].link = nil
                out[run.range].underlineStyle = Text.LineStyle(pattern: .dot)
            } else {
                out[run.range].underlineStyle = .single
            }
            out[run.range].foregroundColor = CarnetTheme.ink
        }
        return out
    }
}

// MARK: - Straight into reading

/// Opens a book in the reader at the member's position: the chapter list is
/// fetched (or read from the offline copy), then the reader takes over.
struct BookResumeView: View {
    let bookId: Int
    let title: String
    let byline: String?

    @State private var chapters: [Chapter] = []
    @State private var start = 0
    @State private var mode: ReaderMode = .full
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var book: Book {
        Book(id: bookId, title: title, authors: byline.map { [$0] } ?? [], tags: nil, formats: nil,
             series: nil, description: nil, chapters: chapters.count, summarized: nil, indexed: nil, added: nil)
    }

    var body: some View {
        Group {
            if !chapters.isEmpty {
                ReaderView(book: book, chapters: chapters, startIndex: start, mode: mode)
            } else {
                VStack(spacing: 0) {
                    GridChromeRow { GridBackButton(size: 40) { dismiss() } }
                    if let error { GridMessage(text: error) } else { GridLoading() }
                }
                .background(CarnetTheme.bg)
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard chapters.isEmpty else { return }
        var list = BookCache.cachedChapters(bookId: bookId) ?? []
        if let fetched = try? await CalibreAPI.chapters(bookId: bookId), !fetched.isEmpty { list = fetched }
        guard !list.isEmpty else {
            error = "This book has no chapters to read yet.\nExtract it from its page first."
            return
        }
        // The reader restores from the local record, brought up to the
        // server's first when another device has read on since: resuming
        // from a stale copy wrote it back and moved the other device back.
        // Offline, the local record stands.
        let server = try? await CalibreAPI.readingProgress(bookId: bookId)
        let local = ReadingPositionStore.reconcile(bookId: bookId, with: server)
        let slug = local?.chapterSlug ?? server?.chapterSlug
        let view = local?.lastView ?? server?.view
        start = slug.flatMap { s in list.firstIndex { $0.slug == s } } ?? 0
        mode = view == "summary" && list[start].hasSummary ? .summary : .full
        chapters = list
    }
}

/// Opens an article's captured text in the reader.
struct ArticleReadView: View {
    let slug: String
    let locale: String

    @State private var article: Article?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let article {
                ArticleReaderView(article: article)
            } else {
                VStack(spacing: 0) {
                    GridChromeRow { GridBackButton(size: 40) { dismiss() } }
                    if let error { GridMessage(text: error) } else { GridLoading() }
                }
                .background(CarnetTheme.bg)
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .task {
            guard article == nil else { return }
            do { article = try await GardenAPI.article(slug: slug, locale: locale).article }
            catch { self.error = "Couldn't load this article.\n\(error.localizedDescription)" }
        }
    }
}
