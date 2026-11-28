import SwiftUI

/// The member sheet, opened from the member's avatar: the households and the
/// members of this one, what waits to be sent, adding a device, the two ways
/// out (sign out, forget the household), inviting a friend as a guest,
/// privacy and deleting the account.
/// A system list, the same as the Maurice app's settings.
struct MemberSwitchSheet: View {
    @Environment(CarnetSession.self) private var session
    @Environment(SyncService.self) private var sync
    @Environment(AIConsentStore.self) private var aiConsent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var pinFor: CarnetAPI.Member?
    @State private var addingHousehold = false
    @State private var addingDevice = false
    @State private var connectingBrowser = false
    @State private var invitingGuest = false
    @State private var forgetting = false
    @State private var deleting = false
    @State private var reviewingAI = false

    var body: some View {
        NavigationStack {
            List {
                households
                members
                pending
                Section {
                    Button { addingDevice = true } label: {
                        Label(L("devices.add"), systemImage: "qrcode")
                    }
                    Button { connectingBrowser = true } label: {
                        Label(L("browser.connect"), systemImage: "safari")
                    }
                    // A guest may not invite; a child only when the admin
                    // allowed it, which the server says.
                    if session.activeMember?.role != "guest" {
                        Button { invitingGuest = true } label: {
                            Label(L("guest.invite"), systemImage: "person.badge.plus")
                        }
                    }
                    Button { signOut() } label: {
                        Label(L("settings.disconnect"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    Button(role: .destructive) { forgetting = true } label: {
                        Label(L("picker.disconnect"), systemImage: "house.slash")
                    }
                }
                privacy
            }
            .navigationTitle(session.currentHouseholdName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
                }
            }
        }
        .tint(CarnetTheme.ink)
        .presentationDetents([.medium, .large])
        .sheet(item: $pinFor) { member in
            PINSheet(member: member) { pin in
                let problem = await session.unlock(member, pin: pin)
                if problem == nil { dismiss() }
                return problem
            }
        }
        .sheet(isPresented: $addingHousehold) { WelcomeView(onDone: { addingHousehold = false; dismiss() }) }
        .sheet(isPresented: $addingDevice) { AddDeviceSheet() }
        .sheet(isPresented: $connectingBrowser) { AddDeviceSheet(forBrowser: true) }
        .sheet(isPresented: $invitingGuest) { GuestInviteSheet() }
        .sheet(isPresented: $deleting) { DeleteAccountSheet() }
        .forgetHouseholdDialog(isPresented: $forgetting, session: session) { dismiss() }
    }

    // MARK: - Sections

    @ViewBuilder private var households: some View {
        Section(L("sheet.households")) {
            ForEach(session.households) { h in
                Button {
                    guard h.id != session.currentHouseholdId else { return }
                    session.switchHousehold(h.id)
                    dismiss()
                } label: {
                    HStack {
                        Label(h.name, systemImage: "house")
                            .foregroundStyle(CarnetTheme.ink)
                        Spacer()
                        if h.id == session.currentHouseholdId {
                            Text(L("sheet.active")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button { addingHousehold = true } label: {
                Label(L("household.add"), systemImage: "plus")
            }
        }
    }

    @ViewBuilder private var members: some View {
        Section(L("sheet.members")) {
            ForEach(session.deviceMembers) { member in
                Button { tap(member) } label: {
                    HStack(spacing: 12) {
                        MemberBadge(member: member, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.display_name).foregroundStyle(CarnetTheme.ink)
                            if member.has_pin {
                                Text(L("sheet.pin_required")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if member.id == session.activeMemberId {
                            Text(L("sheet.you")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// Captures made by a member who has no session here any more: kept, and
    /// sent once they sign in again.
    @ViewBuilder private var pending: some View {
        if !sync.stranded.isEmpty {
            Section(L("pending.section")) {
                ForEach(Array(sync.stranded.keys), id: \.self) { origin in
                    Text(pendingLine(origin, count: sync.stranded[origin] ?? 0))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var privacy: some View {
        Section(L("privacy.section")) {
            Button { openURL(URL(string: "https://www.chezmaurice.eu/privacy.html")!) } label: {
                Label(L("privacy.policy"), systemImage: "hand.raised")
            }
            Button { openURL(URL(string: "https://www.chezmaurice.eu/terms.html")!) } label: {
                Label(L("privacy.terms"), systemImage: "doc.text")
            }
            if session.activeMember != nil {
                // The answer about the AI providers, to read or change.
                Button { reviewingAI = true } label: {
                    Label(L("ai.consent.carnet.row"), systemImage: "server.rack")
                }
                .sheet(isPresented: $reviewingAI) {
                    AIConsentView(onClose: { reviewingAI = false })
                        .task { await aiConsent.refresh() }
                }
                Button(role: .destructive) { deleting = true } label: {
                    Label(L("mydata.delete.button"), systemImage: "person.crop.circle.badge.xmark")
                }
            }
        }
    }

    // MARK: - Actions

    private func tap(_ member: CarnetAPI.Member) {
        if member.id == session.activeMemberId { dismiss(); return }
        if member.has_pin { pinFor = member; return }
        if session.switchToMember(member.id) { dismiss(); return }
        // No PIN and no session here: the server never opens one on a
        // member's id alone. « Who's here? » offers the invitation code.
        session.activeMemberId = nil
        dismiss()
    }

    /// « Sign out »: this member's session ends and what the device keeps for
    /// them goes; the household stays, back on « Who's here? ».
    private func signOut() {
        guard let id = session.activeMemberId else { return }
        session.logoutMember(id)
        dismiss()
    }

    private func pendingLine(_ origin: QueueOrigin, count: Int) -> String {
        let household = session.households.first { $0.id == origin.householdId }
        let who = household?.deviceMembers.first { $0.id == origin.memberId }?.display_name ?? "—"
        if let place = household?.name {
            return count == 1 ? L("pending.one", who, place) : L("pending.other", count, who, place)
        }
        return count == 1 ? L("pending.one.nohousehold", who) : L("pending.other.nohousehold", count, who)
    }
}

// MARK: - Delete account

/// The last step before the account goes: the username typed, the password or
/// PIN asked again. Nothing is sent until both are there. Same contract as the
/// Maurice app's « Delete my account ».
private struct DeleteAccountSheet: View {
    @Environment(CarnetSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var confirm = ""
    @State private var secret = ""
    @State private var busy = false
    @State private var failure: String?

    private var ready: Bool {
        !busy && !username.isEmpty && confirm.trimmingCharacters(in: .whitespaces) == username && !secret.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L("delete.text"))
                }
                Section {
                    TextField(username.isEmpty ? L("picker.admin.username") : username, text: $confirm)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(L("delete.field"), text: $secret)
                } footer: {
                    if !username.isEmpty { Text(L("delete.confirm_footer", username)) }
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
                Section {
                    Button(role: .destructive) { Task { await delete() } } label: {
                        HStack {
                            Text(L("delete.confirm"))
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!ready)
                }
            }
            .navigationTitle(L("mydata.delete.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("common.cancel")) { dismiss() } }
            }
            .task { await loadUsername() }
        }
    }

    private func loadUsername() async {
        if let known = session.activeMember?.username { username = known; return }
        guard let token = CarnetAPI.authToken else { return }
        do { username = try await CarnetAPI.me(token: token).username ?? "" }
        catch { failure = error.localizedDescription }
    }

    private func delete() async {
        guard let id = session.activeMemberId else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            try await CarnetAPI.deleteAccount(confirm: confirm.trimmingCharacters(in: .whitespaces), secret: secret)
            session.logoutMember(id)
            session.updateDeviceMembers(session.deviceMembers.filter { $0.id != id })
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
