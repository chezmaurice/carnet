import SwiftUI

/// « Who's here? » — the household's name, its members, and the ways in:
/// tap a member (their PIN if they have one), join with an invitation, or
/// sign in as admin. Other options hold what is not a member: the
/// invitation, the admin, forgetting the household.
struct WhoIsHereView: View {
    @Environment(CarnetSession.self) private var session
    @State private var members: [CarnetAPI.Member] = []
    @State private var loading = true
    @State private var failure: String?
    /// False when the server has no administrator yet.
    @State private var setupComplete = true

    @State private var pinFor: CarnetAPI.Member?
    @State private var join: JoinRequest?
    @State private var admin = false
    @State private var forgetting = false
    @State private var addingHousehold = false

    private struct JoinRequest: Identifiable {
        let id = UUID()
        var code: String?
        var reason: String?
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 24) {
                        header
                        content
                        if let failure {
                            Text(failure).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                        } else if session.sessionEnded {
                            Text(L("picker.session_ended"))
                                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        optionsMenu
                    }
                    .entryCard()
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .refreshable { await fetchMembers() }
            }
            .entryBackdrop()
        }
        .task { await fetchMembers() }
        .task(id: session.pendingInvitation?.code ?? "") { takePending() }
        .sheet(item: $pinFor) { member in
            PINSheet(member: member) { pin in await session.unlock(member, pin: pin) }
        }
        .sheet(item: $join, onDismiss: { session.pendingInvitation = nil }) { request in
            JoinSheet(code: request.code, reason: request.reason)
        }
        .sheet(isPresented: $admin) { AdminSheet(creating: !setupComplete) }
        .sheet(isPresented: $addingHousehold) { WelcomeView(onDone: { addingHousehold = false }) }
        .forgetHouseholdDialog(isPresented: $forgetting, session: session)
    }

    // MARK: - Parts

    private var header: some View {
        VStack(spacing: 6) {
            // Several households: the name is the switcher.
            if session.households.count > 1 {
                householdMenu
            } else {
                householdName
            }
            Text(L("picker.title"))
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        if loading && members.isEmpty {
            ProgressView().padding(32)
        } else if members.isEmpty {
            VStack(spacing: 16) {
                Text(setupComplete ? L("picker.empty") : L("picker.admin.subtitle"))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if setupComplete {
                    Button { join = JoinRequest() } label: {
                        Text(L("enroll.cta")).frame(maxWidth: 320)
                    }
                    .glassProminentButton().controlSize(.large).tint(CarnetTheme.ink)
                } else {
                    Button { admin = true } label: {
                        Text(L("admin.create")).frame(maxWidth: 320)
                    }
                    .glassProminentButton().controlSize(.large).tint(CarnetTheme.ink)
                }
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 20)], spacing: 24) {
                ForEach(members) { member in
                    Button { tap(member) } label: { MemberTile(member: member) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            if setupComplete {
                Button { join = JoinRequest() } label: { Label(L("enroll.cta"), systemImage: "ticket") }
            }
            Button { admin = true } label: {
                Label(setupComplete ? L("picker.admin_signin") : L("admin.create"), systemImage: "key")
            }
            Divider()
            Button(role: .destructive) { forgetting = true } label: {
                Label(L("picker.disconnect"), systemImage: "house.slash")
            }
        } label: {
            Text(L("welcome.more_options"))
                .font(.subheadline)
                .padding(.vertical, 4)
        }
        .tint(CarnetTheme.inkSoft)
    }

    private var householdName: some View {
        Text(session.currentHouseholdName)
            .font(CarnetTheme.display(30))
            .foregroundStyle(CarnetTheme.ink)
            .multilineTextAlignment(.center)
            // A household still named after its address: one line, smaller,
            // rather than a host cut in the middle of a word.
            .lineLimit(2)
            .minimumScaleFactor(0.5)
    }

    private var householdMenu: some View {
        Menu {
            ForEach(session.households) { h in
                Button {
                    session.switchHousehold(h.id)
                } label: {
                    if h.id == session.currentHouseholdId {
                        Label(h.name, systemImage: "checkmark")
                    } else {
                        Text(h.name)
                    }
                }
            }
            Divider()
            Button { addingHousehold = true } label: { Label(L("household.add"), systemImage: "plus") }
        } label: {
            HStack(spacing: 6) {
                householdName
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityHint(L("foyer.switch_title"))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func tap(_ member: CarnetAPI.Member) {
        failure = nil
        // PIN-protected members always re-verify, even with a session here.
        if member.has_pin { pinFor = member; return }
        if session.switchToMember(member.id) { return }
        // No PIN and no session on this device: the server never opens one on
        // a member's id alone. An invitation code is the way in.
        join = JoinRequest(reason: L("picker.needs_invite", member.display_name))
    }

    /// An invitation received (a link, a scan, the welcome screen's field):
    /// join with it now.
    private func takePending() {
        if let invitation = session.pendingInvitation {
            join = JoinRequest(code: invitation.code)
        }
    }

    private func fetchMembers() async {
        loading = true
        failure = nil
        defer { loading = false }
        // Any member's session here reads the roster. One the server refuses
        // is forgotten (CarnetAPI.note) and the next is tried.
        var lastError: Error?
        for token in session.deviceMembers.compactMap({ session.tokenForMember($0.id) }) {
            do {
                members = try await CarnetAPI.listMembers(token: token)
                session.updateDeviceMembers(members)
                return
            } catch {
                lastError = error
            }
        }
        members = []
        if let lastError, session.deviceMembers.contains(where: { session.tokenForMember($0.id) != nil }) {
            failure = lastError.localizedDescription
            return
        }
        // No session here: ask whether the server still needs its first admin.
        let health = try? await CarnetAPI.health()
        setupComplete = health?.setup_complete ?? true
    }
}

/// A member on « Who's here? »: their picture or initial, their name, a lock
/// when a PIN guards them.
private struct MemberTile: View {
    let member: CarnetAPI.Member

    var body: some View {
        VStack(spacing: 8) {
            MemberBadge(member: member, size: 68)
            HStack(spacing: 4) {
                Text(member.display_name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(CarnetTheme.ink)
                    .lineLimit(1)
                if member.has_pin {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L("sheet.pin_required"))
                }
            }
        }
        .contentShape(Rectangle())
    }
}
