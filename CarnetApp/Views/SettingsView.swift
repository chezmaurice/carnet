import SwiftUI

struct SettingsView: View {
    @Environment(CarnetSession.self) private var session
    @AppStorage(DictationPrefs.preferHouseholdKey) private var preferHousehold = DictationPrefs.preferHouseholdDefault

    /// Editable draft of the server URL. Committed to the session on submit /
    /// "Test connection" so live keystrokes don't momentarily unpair the app.
    @State private var serverURLDraft = ""
    @State private var pingResult: String?
    @State private var isPinging = false

    // Garden links — where the site is served, and how the editors name the
    // checkout. Stored in the shared App Group defaults (GardenLinks reads them).
    @AppStorage(GardenLinks.webURLKey, store: CarnetAPI.defaults)
    private var gardenWebURL = ""
    @AppStorage(GardenLinks.workingCopyRepoKey, store: CarnetAPI.defaults)
    private var workingCopyRepo = ""
    @AppStorage(GardenLinks.obsidianVaultKey, store: CarnetAPI.defaults)
    private var obsidianVault = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let active = session.activeMember {
                        LabeledContent("Signed in as", value: active.display_name)
                    }
                    ForEach(session.deviceMembers.filter { $0.id != session.activeMemberId }) { member in
                        Button {
                            switchTo(member)
                        } label: {
                            HStack {
                                Text(member.display_name)
                                Spacer()
                                if member.has_pin {
                                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                                }
                                Image(systemName: "arrow.left.arrow.right").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Sign out") {
                        if let id = session.activeMemberId { session.logoutMember(id) }
                    }
                    Button("Disconnect server", role: .destructive) {
                        session.unpair()
                    }
                }

                Section {
                    TextField("http://macmini.local:3001", text: $serverURLDraft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onSubmit { commitAndPing() }

                    Button {
                        commitAndPing()
                    } label: {
                        HStack {
                            Text("Save & test connection")
                            Spacer()
                            if isPinging {
                                ProgressView()
                            } else if let result = pingResult {
                                Text(result)
                                    .foregroundStyle(result == "OK" ? .green : .red)
                                    .font(.caption)
                            }
                        }
                    }
                    .disabled(isPinging || serverURLDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("API Server")
                } footer: {
                    Text("The address of your Maurice household server.")
                }

                Section {
                    TextField("http://macmini.local:4321", text: $gardenWebURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    TextField("Working Copy repo", text: $workingCopyRepo)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    TextField("Obsidian vault", text: $obsidianVault)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                } header: {
                    Text("Site & copy")
                } footer: {
                    Text("Where your site is served (defaults to the API host on :4321), and the names of the Working Copy repo / Obsidian vault holding your copy of your notes (default: your username).")
                }

                Section {
                    Toggle("Transcribe on the household server", isOn: $preferHousehold)
                } header: {
                    Text("Dictation")
                } footer: {
                    Text("Your household's server hears the whole recording at once (Whisper), which gets punctuation and names right far more often than the device. The device still writes the words as you speak; the server's text replaces them when you stop. On a home server the audio stays in the house. Turn this off to keep dictation on this device.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
            }
            .navigationTitle("Settings")
            .onAppear { serverURLDraft = session.serverURL ?? "" }
        }
    }

    /// Fast-switch to another member. PIN-protected members are sent back
    /// through the picker so the PIN is always re-verified.
    private func switchTo(_ member: CarnetAPI.Member) {
        if member.has_pin {
            session.activeMemberId = nil
        } else {
            _ = session.switchToMember(member.id)
        }
    }

    private func commitAndPing() {
        let url = serverURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        session.serverURL = url // also updates CarnetAPI.baseURL via the App Group
        Task { await ping() }
    }

    private func ping() async {
        isPinging = true
        pingResult = nil
        defer { isPinging = false }
        do {
            let health = try await CarnetAPI.health()
            pingResult = health.status == "ok" ? "OK" : "Error"
        } catch {
            pingResult = error.localizedDescription
        }
    }
}
