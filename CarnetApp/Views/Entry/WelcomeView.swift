import SwiftUI

/// The way in, the same in Maurice and Carnet on every platform: the app's
/// emblem and name with « Chez Maurice » beneath, what it promises, one main
/// action (scan the invitation), and one field for a code, a link or an
/// address. Signing in as admin needs a household, so it lives on « Who's
/// here? », reached by typing the household's address: the way in that needs
/// no QR code.
///
/// Also presented as a sheet to add another household (`onDone`).
struct WelcomeView: View {
    @Environment(CarnetSession.self) private var session
    var onDone: (() -> Void)? = nil

    @State private var showScanner = false
    @State private var showEntry = false
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                header
                actions
            }
            .entryCard()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .entryBackdrop()
            .toolbar {
                if let onDone {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("common.cancel")) { onDone() }
                    }
                }
            }
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { scanned in Task { await take(scanned) } }
        }
        .sheet(isPresented: $showEntry) {
            EntrySheet { onDone?() }
        }
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(L("common.done"), role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image("carnet-emblem")
                .resizable()
                // The emblem sits in the middle of the icon's square canvas.
                .scaledToFill()
                .frame(width: 180, height: 92)
                .clipped()
                .foregroundStyle(CarnetTheme.ink)
                .accessibilityHidden(true)
            Text("Carnet")
                .font(CarnetTheme.display(38))
                .foregroundStyle(CarnetTheme.ink)
            Text(verbatim: "Chez Maurice")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(L("welcome.promise.carnet"))
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(CarnetTheme.inkSoft)
                .padding(.top, 8)
            Text(L("pairing.instructions"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button { showScanner = true } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView() } else { Image(systemName: "qrcode.viewfinder") }
                    Text(L("invite.scan"))
                }
                .frame(maxWidth: .infinity)
            }
            .glassProminentButton()
            .controlSize(.large)
            .tint(CarnetTheme.ink)
            .disabled(busy)

            Button { showEntry = true } label: {
                Text(L("welcome.enter_code")).frame(maxWidth: .infinity)
            }
            .glassBorderedButton()
            .controlSize(.large)
            .tint(CarnetTheme.ink)
        }
    }

    /// A scanned QR: an invitation link, or nothing of ours.
    private func take(_ scanned: String) async {
        guard let invitation = Invitation(scanned) else {
            failure = L("invite.scan.not_invitation")
            return
        }
        busy = true
        defer { busy = false }
        if let problem = await EntrySheet.probe(invitation.server) {
            failure = problem
            return
        }
        session.receive(invitation)
        onDone?()
    }
}

// MARK: - Entering a code, a link or an address

/// One field for whatever the person was given. A link has everything; an
/// address alone pairs and leads to « Who's here? »; a code alone asks for
/// the household's address next, then pairs and enrolls in one go.
struct EntrySheet: View {
    var onPaired: () -> Void = {}

    @Environment(CarnetSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var address = ""
    /// A code alone was entered: the address is asked for below it.
    @State private var needsAddress = false
    @State private var busy = false
    @State private var failure: String?
    @FocusState private var focus: Field?

    private enum Field { case main, address }

    /// The host half of `pairing.url_placeholder` (« XXXX-XXXX or myhome.chezmaurice.eu »).
    private var addressPlaceholder: String {
        L("pairing.url_placeholder").split(separator: " ").last.map(String.init) ?? "chezmaurice.eu"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("pairing.url_placeholder"), text: $text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                        .focused($focus, equals: .main)
                        .submitLabel(needsAddress ? .next : .go)
                        .onSubmit { needsAddress ? (focus = .address) : submit() }
                        .onChange(of: text) { needsAddress = false; failure = nil }
                } header: {
                    Text(L("welcome.enter_code"))
                } footer: {
                    if !needsAddress, let failure { Text(failure).foregroundStyle(.red) }
                }

                if needsAddress {
                    Section {
                        TextField(addressPlaceholder, text: $address)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.URL)
                            .focused($focus, equals: .address)
                            .submitLabel(.go)
                            .onSubmit(submit)
                    } header: {
                        Text(L("welcome.address_needed"))
                    } footer: {
                        if let failure { Text(failure).foregroundStyle(.red) }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button(L("pairing.connect"), action: submit).disabled(!canSubmit)
                    }
                }
            }
            .onAppear { focus = .main }
        }
        .presentationDetents([.medium, .large])
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
            && (!needsAddress || !address.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func submit() {
        guard canSubmit, !busy else { return }
        failure = nil
        switch EntryInput(text) {
        case .invitation(let invitation):
            Task { await enter(server: invitation.server) { session.receive(invitation) } }
        case .code(let code):
            guard needsAddress else { needsAddress = true; focus = .address; return }
            guard let server = EntryInput.normalizedAddress(address) else {
                failure = L("pairing.error.invalid_url"); return
            }
            Task { await enter(server: server) { session.receive(Invitation(server: server, code: code)) } }
        case .address(let server):
            Task {
                await enter(server: server) {
                    session.pair(serverURL: server)
                    session.sessionEnded = false
                }
            }
        case nil:
            failure = L("pairing.error.invalid_url")
        }
    }

    private func enter(server: String, then go: () -> Void) async {
        busy = true
        defer { busy = false }
        if let problem = await Self.probe(server) {
            failure = problem
            return
        }
        go()
        dismiss()
        onPaired()
    }

    /// Nil when a household answers at `server`; otherwise what to tell the person.
    static func probe(_ server: String) async -> String? {
        do {
            let health = try await CarnetAPI.health(at: server)
            return health.status == "ok" ? nil : L("pairing.error.status")
        } catch {
            if server.hasPrefix("http://") { return L("pairing.error.https_hint") }
            return L("pairing.error.connect", L("pairing.error.unreachable"))
        }
    }
}
