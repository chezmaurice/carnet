import SwiftUI

/// The page of a domain: the brief Maurice keeps on it, as it stands —
/// editable (what the member writes is what Maurice reads from the next
/// turn on), erasable, with when it was last rewritten and by whom, and a
/// "rewrite now" that asks the night's model for a fresh one. Reading and
/// correcting, which is what Carnet is for; the domain itself (its name,
/// statement, context, model) is edited in the Maurice app.
struct DomainBriefView: View {
    let domain: DomainSummary
    @Environment(\.dismiss) private var dismiss

    @State private var loaded = false
    @State private var error: String?
    @State private var brief: DomainBrief?
    @State private var text = ""
    @State private var saving = false
    @State private var refreshing = false
    @State private var notice: String?
    @State private var confirmErase = false
    @FocusState private var editing: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool { trimmed != (brief?.text ?? "") }
    private var busy: Bool { saving || refreshing }

    var body: some View {
        Group {
            if !loaded {
                GridLoading()
            } else if let error {
                GridMessage(text: error)
            } else {
                content
            }
        }
        .background(CarnetTheme.bg)
        .gridTopChrome {
            GridChromeRow {
                GridBackButton { dismiss() }
            } trailing: {
                if editing {
                    Button { editing = false } label: {
                        GridIconGlyph(systemName: "keyboard.chevron.compact.down", size: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide keyboard")
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .confirmationDialog("Erase this brief?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) { Task { await erase() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Maurice forgets what he kept on this domain. The next night, or Rewrite now, writes a fresh one.")
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header — mark, kicker, name, tagline
                HStack(alignment: .top, spacing: 16) {
                    DomainMark(systemName: "book.closed", size: 62)
                    VStack(alignment: .leading, spacing: 0) {
                        GridLabel("Domain", size: 9)
                        Text(domain.name)
                            .font(CarnetTheme.display(22, weight: .bold))
                            .tracking(-0.4)
                            .foregroundStyle(CarnetTheme.ink)
                            .padding(.top, 4)
                        if let t = domain.tagline, !t.isEmpty {
                            Text(t)
                                .font(CarnetTheme.sans(13))
                                .foregroundStyle(CarnetTheme.inkMute)
                                .padding(.top, 4)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 18)

                GridRule()

                // Status — who wrote it, when, from how much
                status
                    .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                    .padding(.vertical, 12)

                GridRule()

                // The brief itself
                editor
                    .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                    .padding(.top, 14)

                if let notice {
                    Text(notice)
                        .font(CarnetTheme.mono(10))
                        .foregroundStyle(CarnetTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                        .padding(.top, 10)
                }

                actions
                    .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                    .padding(.top, 16)

                Text("Maurice reads this brief in every conversation you have alone with him — never in a room. What you write here is what he reads from the next turn on, and what the next night starts from; erase it and he forgets.")
                    .font(CarnetTheme.caption)
                    .foregroundStyle(CarnetTheme.inkMute)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                    .padding(.top, 20)
            }
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: status

    @ViewBuilder private var status: some View {
        if let brief {
            HStack(spacing: 8) {
                Image(systemName: brief.byMember ? "person" : "moon.stars")
                    .font(.system(size: 12)).foregroundStyle(CarnetTheme.inkSoft)
                VStack(alignment: .leading, spacing: 3) {
                    GridLabel(brief.byMember ? "In your words" : "Written by Maurice", size: 9.5, color: CarnetTheme.inkSoft)
                    HStack(spacing: 6) {
                        let age = ServerDate.age(brief.updated_at)
                        Text((age.isEmpty ? "" : "\(age) · ") + ServerDate.absolute(brief.updated_at))
                        if !brief.byMember, brief.sourceCount > 0 {
                            Text("· \(brief.sourceCount) conversation\(brief.sourceCount == 1 ? "" : "s") read")
                        }
                    }
                    .font(CarnetTheme.mono(10))
                    .foregroundStyle(CarnetTheme.inkMute)
                }
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz").font(.system(size: 12)).foregroundStyle(CarnetTheme.inkMute)
                Text("No brief yet. The night writes one when the domain has been talked about, or Rewrite now asks for it.")
                    .font(CarnetTheme.sans(12.5))
                    .foregroundStyle(CarnetTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: editor

    /// The brief is read more than it is edited: the editor grows with the
    /// text instead of scrolling inside the page (a hidden twin of the text
    /// gives the editor its height — TextEditor sizes itself to nothing).
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            Text(text.isEmpty ? " " : text)
                .font(CarnetTheme.sans(15))
                .lineSpacing(3)
                .padding(.horizontal, 5).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(0)
                .accessibilityHidden(true)
            TextEditor(text: $text)
                .font(CarnetTheme.sans(15))
                .lineSpacing(3)
                .foregroundStyle(CarnetTheme.ink)
                .focused($editing)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
        }
            .frame(minHeight: 200)
            .padding(12)
            .background(CarnetTheme.surface)
            .overlay(Rectangle().strokeBorder(editing ? CarnetTheme.ink : CarnetTheme.ruleHard, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Write what Maurice should keep on this domain — or leave it to the night.")
                        .font(CarnetTheme.sans(15))
                        .foregroundStyle(CarnetTheme.inkHint)
                        .padding(.horizontal, 17).padding(.vertical, 20)
                        .allowsHitTesting(false)
                }
            }
            .disabled(busy)
            .accessibilityLabel("Brief")
    }

    // MARK: actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                GridButton(title: "Save", systemImage: "checkmark", primary: changed && !busy, small: true) {
                    Task { await save() }
                }
                .disabled(!changed || busy)

                GridButton(title: refreshing ? "Rewriting…" : "Rewrite now", systemImage: "arrow.clockwise", small: true) {
                    Task { await rewrite() }
                }
                .disabled(busy)
            }
            if brief != nil {
                Button { confirmErase = true } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "trash").font(.system(size: 12))
                        Text("Erase").font(CarnetTheme.sans(12.5, weight: .semibold))
                    }
                    .foregroundStyle(CarnetTheme.accent)
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .overlay(Rectangle().strokeBorder(CarnetTheme.ruleHard, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .opacity(busy ? 0.5 : 1)
            }
        }
    }

    // MARK: server

    private func load() async {
        do {
            let r = try await DomainsAPI.brief(domainId: domain.id)
            brief = r.brief
            text = r.brief?.text ?? ""
            error = nil
        } catch {
            if error.isCancellation { return }
            self.error = "Couldn't load this brief.\n\(error.localizedDescription)"
        }
        loaded = true
    }

    private func save() async {
        guard changed else { return }
        saving = true
        defer { saving = false }
        do {
            let b = try await DomainsAPI.setBrief(domainId: domain.id, text: trimmed)
            brief = b
            text = b?.text ?? ""
            editing = false
            notice = b == nil ? "Erased. Maurice keeps nothing on this domain now." : "Saved. This is what Maurice reads from the next turn on."
        } catch {
            notice = "Couldn't save.\n\(error.localizedDescription)"
        }
    }

    private func erase() async {
        saving = true
        defer { saving = false }
        do {
            try await DomainsAPI.eraseBrief(domainId: domain.id)
            brief = nil
            text = ""
            notice = "Erased. Maurice keeps nothing on this domain now."
        } catch {
            notice = "Couldn't erase.\n\(error.localizedDescription)"
        }
    }

    private func rewrite() async {
        refreshing = true
        notice = "Maurice is rewriting the brief…"
        defer { refreshing = false }
        do {
            let r = try await DomainsAPI.refreshBrief(domainId: domain.id)
            if let b = r.brief { brief = b; text = b.text }
            switch r.outcome {
            case .written(let n): notice = "Rewritten from \(n) conversation\(n == 1 ? "" : "s")."
            case .unchanged: notice = "Nothing new since the last brief — left as it was."
            case .capped: notice = "The night's allowance is spent for today. Try again tomorrow."
            case .failed(let why): notice = "The rewrite failed. \(why)"
            }
        } catch {
            notice = "The rewrite failed.\n\(error.localizedDescription)"
        }
    }
}
