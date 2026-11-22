import SwiftUI

/// The Domains shelf of the Reading section — what Maurice keeps on the
/// member: their domains (each opening its page, the brief), their reading
/// companions (each leading to its book), and the conversations Maurice
/// opened on his own (each readable here, answered in the Maurice app).
/// Same chrome as the two shelves it sits beside.
struct DomainsShelfView: View {
    var onMenu: (() -> Void)? = nil
    var onIdentity: (() -> Void)? = nil
    /// The Books / Articles / Domains toggle, when hosted beside those
    /// shelves. Nil when the screen stands alone under the member's menu,
    /// where it is called Maurice and has a way back.
    var shelf: Binding<ReadingShelf>? = nil
    /// Pushes a Calibre book (a companion's) onto the library's stack.
    var openBook: (Book) -> Void = { _ in }
    var onBack: (() -> Void)? = nil

    @State private var domains: [DomainSummary] = []
    @State private var companions: [CompanionSummary] = []
    @State private var opened: [ConversationRow] = []
    @State private var loading = true
    @State private var error: String?
    @State private var didStartLoad = false
    @State private var resolvingBook: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let shelf {
                    GridTitle(title: "Domains", kicker: loading ? "Maurice" : "Maurice · \(domains.count)")
                    ShelfToggle(shelf: shelf)
                } else {
                    GridTitle(title: "Maurice", kicker: "What Maurice keeps on you")
                }
                if loading {
                    GridLoading().frame(minHeight: 240)
                } else if let error {
                    GridMessage(text: error)
                } else {
                    content
                }
            }
        }
        .refreshable { await fetch() }
        .gridTopChrome {
            GridChromeRow {
                if let onBack { GridBackButton(size: 40, action: onBack) }
                else { ShelfIdentity(menu: onMenu, identity: onIdentity) }
            }
        }
        .background(CarnetTheme.bg)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            // Coming back from a page: a brief was saved or erased, a
            // conversation was read — the rows say so only if we ask again.
            guard !didStartLoad else { Task { await fetch() }; return }
            didStartLoad = true
            Task { await fetch() }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if domains.isEmpty && companions.isEmpty && opened.isEmpty {
                GridRule()
                Text("Nothing here yet. A domain is a part of your life Maurice follows, with a brief he keeps on it; domains are made in the Maurice app until Maurice proposes them himself.")
                    .font(CarnetTheme.subheadline)
                    .foregroundStyle(CarnetTheme.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                    .padding(.vertical, 28)
            }

            if !opened.isEmpty {
                sectionLabel("Opened by Maurice")
                GridRule()
                ForEach(opened) { c in
                    NavigationLink(value: OpenedConversationRoute(id: c.id)) {
                        OpenedConversationRow(conversation: c)
                    }
                    .buttonStyle(.plain)
                    GridRule()
                }
            }

            if !domains.isEmpty {
                sectionLabel("Domains")
                GridRule()
                ForEach(domains) { d in
                    NavigationLink(value: d) {
                        DomainRow(domain: d)
                    }
                    .buttonStyle(.plain)
                    .disabled(!d.isMine)
                    GridRule()
                }
            }

            if !companions.isEmpty {
                sectionLabel("Reading companions")
                GridRule()
                ForEach(companions) { c in
                    Button { open(c) } label: {
                        CompanionRow(companion: c, resolving: resolvingBook == c.id)
                    }
                    .buttonStyle(.plain)
                    .disabled(c.bookId == nil)
                    GridRule()
                }
            }

            if !domains.isEmpty || !companions.isEmpty {
                Text("A brief is what Maurice keeps on a domain and reads in every conversation you have alone with him. Correct it, and that is what he reads from the next turn on. A reading companion follows one book at your reading position; its conversation lives in the Maurice app.")
                    .font(CarnetTheme.caption)
                    .foregroundStyle(CarnetTheme.inkMute)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                    .padding(.vertical, 18)
            }
        }
        .padding(.bottom, 24)
    }

    private func sectionLabel(_ text: String) -> some View {
        GridLabel(text, size: 9.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
            .padding(.top, 18)
            .padding(.bottom, 8)
    }

    /// A companion leads to its book's page — where the reading is.
    private func open(_ c: CompanionSummary) {
        guard let id = c.bookId, resolvingBook == nil else { return }
        if let cached = BookCache.cachedBooksList()?.first(where: { $0.id == id }) {
            openBook(cached); return
        }
        resolvingBook = c.id
        Task {
            defer { resolvingBook = nil }
            if let book = try? await CalibreAPI.metadata(bookId: id) { openBook(book) }
        }
    }

    private func fetch() async {
        do {
            async let ov = DomainsAPI.overview()
            async let convos = DomainsAPI.conversations()
            let (o, c) = try await (ov, convos)
            domains = o.domains
            companions = o.companions
            opened = c.filter(\.openedByMaurice)
            error = nil
        } catch {
            if error.isCancellation { loading = false; return }
            if domains.isEmpty && opened.isEmpty {
                self.error = "Couldn't load your domains.\n\(error.localizedDescription)"
            }
        }
        loading = false
    }
}

/// Where the library's stack lands on a conversation Maurice opened.
struct OpenedConversationRoute: Hashable {
    let id: String
}

// MARK: - Rows

private struct DomainRow: View {
    let domain: DomainSummary

    private var line: String {
        guard domain.isMine else { return "Shared with you" }
        guard let b = domain.brief else { return "No brief yet" }
        let age = ServerDate.age(b.updated_at)
        return (b.byMember ? "In your words" : "Written by Maurice") + (age.isEmpty ? "" : " · \(age)")
    }

    var body: some View {
        HStack(spacing: 14) {
            DomainMark(systemName: "book.closed")
            VStack(alignment: .leading, spacing: 0) {
                Text(domain.name)
                    .font(CarnetTheme.sans(15.5, weight: .semibold))
                    .tracking(-0.15)
                    .foregroundStyle(CarnetTheme.ink)
                    .lineLimit(2)
                if let t = domain.tagline, !t.isEmpty {
                    Text(t)
                        .font(CarnetTheme.sans(12.5))
                        .foregroundStyle(CarnetTheme.inkMute)
                        .padding(.top, 2)
                        .lineLimit(2)
                }
                GridLabel(line, size: 9.5, color: domain.brief == nil ? CarnetTheme.inkMute : CarnetTheme.inkSoft)
                    .padding(.top, 9)
            }
            Spacer(minLength: 0)
            if domain.isMine {
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(CarnetTheme.inkMute)
            }
        }
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.vertical, 15)
        .contentShape(Rectangle())
    }
}

private struct CompanionRow: View {
    let companion: CompanionSummary
    var resolving = false

    var body: some View {
        HStack(spacing: 14) {
            DomainMark(systemName: "book.pages")
            VStack(alignment: .leading, spacing: 0) {
                Text(companion.name)
                    .font(CarnetTheme.sans(15.5, weight: .semibold))
                    .tracking(-0.15)
                    .foregroundStyle(CarnetTheme.ink)
                    .lineLimit(2)
                if let t = companion.tagline, !t.isEmpty {
                    Text(t).font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkMute)
                        .padding(.top, 2).lineLimit(2)
                }
                GridLabel(companion.conversation_id == nil ? "No conversation yet" : "Conversation in the Maurice app",
                          size: 9.5, color: CarnetTheme.inkMute)
                    .padding(.top, 9)
            }
            Spacer(minLength: 0)
            if resolving {
                ProgressView().controlSize(.small).tint(CarnetTheme.inkMute)
            } else if companion.bookId != nil {
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(CarnetTheme.inkMute)
            }
        }
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.vertical, 15)
        .contentShape(Rectangle())
    }
}

private struct OpenedConversationRow: View {
    let conversation: ConversationRow

    var body: some View {
        HStack(spacing: 14) {
            DomainMark(systemName: "bubble.left", on: conversation.isUnread)
            VStack(alignment: .leading, spacing: 0) {
                Text(conversation.title ?? "Maurice")
                    .font(CarnetTheme.sans(15.5, weight: conversation.isUnread ? .semibold : .regular))
                    .tracking(-0.15)
                    .foregroundStyle(CarnetTheme.ink)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    GridLabel("Opened by Maurice", size: 9.5, color: CarnetTheme.inkSoft)
                    let age = ServerDate.age(conversation.created_at)
                    if !age.isEmpty { GridLabel(age, size: 9.5) }
                    if conversation.isUnread { GridLabel("Unread", size: 9.5, color: CarnetTheme.accent) }
                }
                .padding(.top, 9)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(CarnetTheme.inkMute)
        }
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.vertical, 15)
        .contentShape(Rectangle())
    }
}

/// What stands where the Maurice app draws its mark: a glyph in a square on
/// the Grid — a closed book for a domain, open pages for a companion, a
/// bubble for a conversation Maurice opened (filled while unread).
struct DomainMark: View {
    let systemName: String
    var on: Bool = false
    var size: CGFloat = 46

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.4, weight: .regular))
            .foregroundStyle(on ? CarnetTheme.accentInk : CarnetTheme.inkSoft)
            .frame(width: size, height: size)
            .background(on ? CarnetTheme.accent : CarnetTheme.surfaceAlt)
            .overlay(Rectangle().strokeBorder(on ? CarnetTheme.accent : CarnetTheme.rule, lineWidth: 1))
    }
}
