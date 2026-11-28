import SwiftUI
import CoreText

@main
struct CarnetApp: App {
    init() { registerBundledFonts() }

    // APNs registration callbacks land on the delegate; SwiftUI keeps the scene.
    @UIApplicationDelegateAdaptor(CarnetAppDelegate.self) private var appDelegate

    @State private var session = CarnetSession()
    @State private var syncService = SyncService()
    @State private var router = CarnetRouter()

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ReplyGallery.requested { ReplyGallery() } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
            // The member's language (AppLanguage): the whole interface is
            // drawn again in it when it is learnt or changes.
            .environment(\.locale, AppLanguage.locale)
            .id(session.language)
            .environment(session)
            .environment(syncService)
            .environment(router)
            .preferredColorScheme(CarnetTheme.colorSchemeOverride)
            .onAppear { wirePush() }
            // Signed out while offline: nothing else runs once no member is
            // signed in, so the sessions still to close are sent from here.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Task { await SessionClosures.shared.flush() }
            }
            .onOpenURL { open($0) }
            // A tapped https://<household>/join?code=… (universal link).
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { open(url) }
            }
        }
    }

    /// `carnet://join?server=…&code=…` and `https://<household>/join?code=…` —
    /// an invitation or a device code: to « Who's here? » of that household,
    /// where it is used. `carnet://entry/<collection>/<locale>/<slug>` — an
    /// entry of the garden, opened from outside: the Maurice app sends its
    /// member here from what a conversation offered them to keep. Anything
    /// else is ignored.
    private func open(_ url: URL) {
        if let invitation = Invitation(url: url) {
            session.receive(invitation)
            return
        }
        guard url.scheme == "carnet", url.host == "entry" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 3 else { return }
        router.openEntryId = parts.joined(separator: "/")
    }

    /// The device token goes to every paired household; a tapped notification
    /// switches to the household it came from, then opens the conversation
    /// or the entry.
    private func wirePush() {
        let notifications = CarnetNotifications.shared
        notifications.onDeviceToken = { token in
            Task { await notifications.upload(token, session: session) }
        }
        notifications.onOpen = { tap, tag in
            if let tag, tag != session.currentHouseholdId, session.households.contains(where: { $0.id == tag }) {
                session.switchHousehold(tag)
            }
            switch tap {
            case .conversation(let id): router.openConversationId = id
            case .entry(let id): router.openEntryId = id
            }
        }
    }
}

/// Gates the app behind pairing + member sign-in, mirroring Maurice:
/// not paired → WelcomeView; paired but no active member → WhoIsHereView;
/// signed in → the app, after the « before you connect » notice on a server
/// someone else runs.
private struct RootView: View {
    @Environment(CarnetSession.self) private var session
    @Environment(SyncService.self) private var syncService

    private var previewingReading: Bool {
        #if DEBUG
        ReadingPreview.active
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if previewingReading {
                #if DEBUG
                LibraryView(previewBooks: Book.samples, onIdentity: {})
                #endif
            } else if !session.isPaired {
                WelcomeView()
            } else if !session.hasActiveSession {
                WhoIsHereView()
            } else {
                AppShell()
                    .onAppear {
                        syncService.startMonitoring()
                        // Signed in: ask for notifications, register, upload
                        // the token — so a conversation Maurice opens reaches
                        // this phone. A token already granted is re-uploaded
                        // (a member switch changes who it belongs to).
                        CarnetNotifications.shared.requestAuthorizationOnce()
                        if let token = CarnetNotifications.shared.deviceToken {
                            Task { await CarnetNotifications.shared.upload(token, session: session) }
                        }
                    }
                    // Another member's captures may have been waiting for them.
                    .onChange(of: session.activeMemberId) { Task { await syncService.syncNow() } }
                    .sheet(isPresented: disclosureOwed) {
                        ConnectDisclosureSheet(
                            onAccept: {
                                if let host = ConnectDisclosure.owed(by: session) { ConnectDisclosure.acknowledge(host) }
                                disclosureAck.toggle()
                            },
                            onCancel: { session.unpair() }
                        )
                    }
            }
        }
    }

    /// Bumped on acknowledge, so the notice's condition is read again.
    @State private var disclosureAck = false

    private var disclosureOwed: Binding<Bool> {
        Binding(get: { _ = disclosureAck; return ConnectDisclosure.owed(by: session) != nil },
                set: { _ in })
    }
}

// MARK: - Bundled fonts

/// Register the app's bundled serif at launch (CoreText), so we don't depend on
/// an Info.plist UIAppFonts entry. Idempotent — a duplicate registration on a
/// hot reload just no-ops. Young Serif is the Maurice app's display face; text
/// and mono are the system's.
private func registerBundledFonts() {
    for name in ["YoungSerif-Regular"] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "ttf"),
              let data = try? Data(contentsOf: url),
              let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider) else { continue }
        CTFontManagerRegisterGraphicsFont(font, nil)
    }
}
