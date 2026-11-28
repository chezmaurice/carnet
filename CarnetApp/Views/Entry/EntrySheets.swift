import SwiftUI

// The sheets of the way in, shared by « Who's here? » and the member sheet:
// one PIN prompt, one invitation flow, one admin sign-in. System sheets and
// forms, as in the Maurice app; nothing drawn by hand over a black veil.

// MARK: - PIN

/// The one PIN prompt: the member, their PIN, and the way in. `unlock`
/// answers nil when the member is signed in, or what to say otherwise.
struct PINSheet: View {
    let member: CarnetAPI.Member
    let unlock: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var busy = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                MemberBadge(member: member, size: 64)
                Text(member.display_name)
                    .font(.title3.weight(.semibold))
                Text(L("picker.pin.title"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                SecureField(L("picker.pin.placeholder"), text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(.title2.monospacedDigit())
                    .padding(.vertical, 10)
                    .frame(maxWidth: 200)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .focused($focused)
                    .onSubmit { submit() }
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("picker.pin.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button(L("picker.pin.submit"), action: submit).disabled(pin.isEmpty)
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        guard !pin.isEmpty, !busy else { return }
        busy = true
        Task {
            let problem = await unlock(pin)
            busy = false
            if let problem {
                failure = problem
                pin = ""
            } else {
                dismiss()
            }
        }
    }
}

extension CarnetSession {
    /// Sign a member in with their PIN on the current household. Nil when
    /// done, else what to tell them.
    func unlock(_ member: CarnetAPI.Member, pin: String) async -> String? {
        do {
            let resp = try await CarnetAPI.login(userID: member.id, pin: pin)
            guard loginMember(resp.user_id, token: resp.token) else { return L("signin.notkept") }
            var updated = deviceMembers.filter { $0.id != member.id }
            updated.append(member)
            updateDeviceMembers(updated)
            return nil
        } catch {
            return L("picker.pin.error")
        }
    }
}

// MARK: - Invitation

/// Joining with an invitation or a device code: the code (unless it came with
/// a link), then « Who's joining? » for an open invitation, then the PIN a
/// member must set. Ends signed in.
struct JoinSheet: View {
    /// The code already in hand (a link, a scan): sent at once.
    var code: String?
    /// Said above the field: why a code is being asked for.
    var reason: String?

    @Environment(CarnetSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    private enum Step { case code, profile, pin }
    @State private var step: Step = .code
    @State private var typed = ""
    @State private var name = ""
    @State private var color = JoinSheet.colors[0]
    @State private var pin = ""
    @State private var confirm = ""
    @State private var held: (member: CarnetAPI.Member, token: String)?
    @State private var busy = false
    @State private var failure: String?

    /// The member colours on offer — the same eight as the Maurice app's.
    static let colors = ["#2c5aa0", "#7a4f6e", "#b97a1e", "#3d6b4f", "#a6452e", "#e3a7c2", "#44504f", "#9c6b4a"]

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .code: codeStep
                case .profile: profileStep
                case .pin: pinStep
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step != .pin {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("common.cancel")) { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button(step == .pin ? L("pinsetup.submit") : L("enroll.submit"), action: submit)
                            .disabled(!canSubmit)
                    }
                }
            }
            .task {
                if let code, typed.isEmpty {
                    typed = code
                    submit()
                }
            }
        }
        // The PIN a member must set is not optional.
        .interactiveDismissDisabled(step == .pin)
    }

    private var title: String {
        switch step {
        case .code: L("enroll.title")
        case .profile: L("enroll.profile.title")
        case .pin: L("pinsetup.title")
        }
    }

    @ViewBuilder private var codeStep: some View {
        Section {
            TextField(L("enroll.placeholder"), text: $typed)
                .font(.title3.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onSubmit(submit)
        } footer: {
            Text(reason ?? L("enroll.subtitle"))
        }
    }

    @ViewBuilder private var profileStep: some View {
        Section {
            TextField(L("enroll.profile.name"), text: $name)
                .textInputAutocapitalization(.words)
                .textContentType(.givenName)
                .onChange(of: name) { if name.count > 40 { name = String(name.prefix(40)) } }
        } footer: {
            Text(L("enroll.profile.subtitle"))
        }
        Section {
            HStack(spacing: 0) {
                ForEach(Self.colors, id: \.self) { hex in
                    Button { color = hex } label: {
                        Circle()
                            .fill(swatch(hex))
                            .frame(width: 28, height: 28)
                            .overlay {
                                if color == hex {
                                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                }
                            }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var pinStep: some View {
        Section {
            SecureField(L("pinsetup.placeholder"), text: $pin)
                .keyboardType(.numberPad)
                .textContentType(.newPassword)
            SecureField(L("pinsetup.confirm"), text: $confirm)
                .keyboardType(.numberPad)
                .textContentType(.newPassword)
        } footer: {
            Text(L("pinsetup.subtitle"))
        }
    }

    private var canSubmit: Bool {
        switch step {
        case .code: Invitation.normalizedCode(typed) != nil
        case .profile: !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .pin: !pin.isEmpty && !confirm.isEmpty
        }
    }

    private func submit() {
        guard canSubmit, !busy else { return }
        failure = nil
        Task {
            busy = true
            defer { busy = false }
            switch step {
            case .code, .profile: await enroll()
            case .pin: await setPin()
            }
        }
    }

    private func enroll() async {
        guard let code = Invitation.normalizedCode(typed) else { return }
        do {
            let profile = step == .profile
            let resp = try await CarnetAPI.enroll(
                code: code,
                displayName: profile ? String(name.trimmingCharacters(in: .whitespaces).prefix(40)) : nil,
                avatarColor: profile ? color : nil)
            if resp.needs_profile == true {
                step = .profile
                return
            }
            guard let token = resp.token else {
                failure = L("enroll.failed")
                return
            }
            let me = try await CarnetAPI.me(token: token)
            if resp.needs_pin == true {
                held = (me, token)
                step = .pin
            } else {
                finish(me, token: token)
            }
        } catch {
            failure = error.localizedDescription.isEmpty ? L("enroll.failed") : error.localizedDescription
        }
    }

    private func setPin() async {
        guard let held else { return }
        let p = pin.trimmingCharacters(in: .whitespaces)
        guard p.count >= 4, p.count <= 6, p.allSatisfy(\.isNumber) else { failure = L("pinsetup.invalid"); return }
        guard p == confirm.trimmingCharacters(in: .whitespaces) else { failure = L("pinsetup.mismatch"); return }
        do {
            try await CarnetAPI.setPin(p, token: held.token)
            let m = held.member
            finish(CarnetAPI.Member(id: m.id, display_name: m.display_name, avatar_color: m.avatar_color,
                                    has_pin: true, role: m.role, username: m.username, avatar_url: m.avatar_url),
                   token: held.token)
        } catch {
            // The server refuses a PIN that is too easy to guess.
            let said = error.localizedDescription
            failure = said.localizedCaseInsensitiveContains("weak") ? L("pinsetup.weak") : said
        }
    }

    private func finish(_ member: CarnetAPI.Member, token: String) {
        session.pendingInvitation = nil
        // The code is spent either way; say why nobody is signed in.
        guard session.loginMember(member.id, token: token) else {
            failure = L("signin.notkept")
            return
        }
        var updated = session.deviceMembers.filter { $0.id != member.id }
        updated.append(member)
        session.updateDeviceMembers(updated)
        dismiss()
        Task {
            if let roster = try? await CarnetAPI.listMembers(token: token) {
                session.updateDeviceMembers(roster)
            }
        }
    }

    private func swatch(_ hex: String) -> Color {
        CarnetAPI.Member(id: "", display_name: "", avatar_color: hex, has_pin: false, role: nil).color
    }
}

// MARK: - Admin

/// « Sign in as admin »: the household's administrator with their password —
/// the way in that needs no QR code. On a server with no administrator yet,
/// creates one.
struct AdminSheet: View {
    /// The server has no administrator yet: create one.
    let creating: Bool

    @Environment(CarnetSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("picker.admin.username"), text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField(L("picker.admin.password"), text: $password)
                        .textContentType(creating ? .newPassword : .password)
                        .onSubmit(submit)
                } footer: {
                    if !creating { Text(L("picker.admin.subtitle")) }
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle(creating ? L("admin.create") : L("picker.admin.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("picker.admin.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button(creating ? L("admin.create") : L("picker.admin.submit"), action: submit)
                            .disabled(username.isEmpty || password.isEmpty)
                    }
                }
            }
        }
    }

    private func submit() {
        guard !username.isEmpty, !password.isEmpty, !busy else { return }
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do {
                let id: String, token: String
                if creating {
                    let resp = try await CarnetAPI.setup(username: username, password: password, displayName: username)
                    (id, token) = (resp.user.id, resp.token)
                } else {
                    let resp = try await CarnetAPI.login(username: username, password: password)
                    (id, token) = (resp.user_id, resp.token)
                }
                guard session.loginMember(id, token: token) else {
                    failure = L("signin.notkept")
                    return
                }
                if let roster = try? await CarnetAPI.listMembers(token: token) {
                    session.updateDeviceMembers(roster)
                }
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

// MARK: - Forgetting a household

extension View {
    /// The confirmation before « Forget this household »: what goes with it,
    /// and the captures that would never be sent.
    func forgetHouseholdDialog(isPresented: Binding<Bool>, session: CarnetSession,
                               onForget: @escaping () -> Void = {}) -> some View {
        let name = session.currentHouseholdName
        let pending = OfflineQueue.shared.pendingItems()
            .filter { $0.origin?.householdId == session.currentHouseholdId }.count
        let body = L("household.forget.body")
        let message = pending == 0 ? body
            : body + "\n\n" + (pending == 1 ? L("household.forget.pending.one")
                                            : L("household.forget.pending.other", pending))
        return confirmationDialog(L("household.forget.title", name), isPresented: isPresented,
                                  titleVisibility: .visible) {
            Button(L("household.forget.confirm"), role: .destructive) {
                session.unpair()
                onForget()
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}
