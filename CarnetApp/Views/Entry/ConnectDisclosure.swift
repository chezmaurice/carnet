import SwiftUI

/// The « before you connect » notice, shown once per server to a member who
/// does not run it: who controls the household, what stays private. Same
/// moment and same words as the Maurice app (its copy follows the safety
/// spec verbatim, in English, there as here). « Cancel » forgets the household.
enum ConnectDisclosure {
    private static func key(_ host: String) -> String { "carnet.connect_disclosure.\(host)" }
    static func acknowledged(_ host: String) -> Bool { UserDefaults.standard.bool(forKey: key(host)) }
    static func acknowledge(_ host: String) { UserDefaults.standard.set(true, forKey: key(host)) }

    /// The host the notice is about, when it is still owed for the signed-in member.
    static func owed(by session: CarnetSession) -> String? {
        guard session.hasActiveSession,
              (session.activeMember?.role ?? "") != "admin",
              let url = session.serverURL, let host = URL(string: url)?.host,
              !acknowledged(host) else { return nil }
        return host
    }
}

struct ConnectDisclosureSheet: View {
    let onAccept: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: "You're joining a Maurice server run by someone else.")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 10) {
                        bullet("The operator of this server controls how Maurice behaves here — its personality and its instructions.")
                        bullet("Anything you post in a shared room is visible to other members of that room, and to the operator.")
                        bullet("Your private conversations stay private. Maurice keeps each member's personal data isolated, and the operator cannot read it.")
                        bullet("You can leave any room, block other members, and report content at any time.")
                    }
                    Text(verbatim: "If you weren't expecting to join this server, or someone you don't know asked you to install Maurice and connect here, don't connect.")
                        .bold()
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: onAccept) {
                    Text(verbatim: "I understand — Connect").frame(maxWidth: .infinity)
                }
                .glassProminentButton()
                .controlSize(.large)
                .tint(CarnetTheme.ink)
                .padding(24)
            }
            .navigationTitle(Text(verbatim: "Before you connect"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel, action: onCancel) { Text(verbatim: "Cancel") }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "•")
            Text(s)
        }
    }
}
