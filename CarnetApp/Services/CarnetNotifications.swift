import Foundation
import UIKit
import UserNotifications

// MARK: - Push: the conversation Maurice opens reaches this phone
//
// Carnet keeps no socket to the server, so every event it should hear about
// comes as an APNs push — the conversation Maurice opens on his own
// (server: services/openedConversations.ts → services/push.ts), and an entry
// another member shares with this one (data-api/services/entryShares.ts). The app asks
// for permission once a member is signed in, registers the device, and hands
// the token to every paired household, tagged with the local household id;
// a tap on the notification opens the conversation in Carnet (read there,
// answered in the Maurice app). Same shape as the Maurice app's
// NotificationManager, minus the local notifications a socket would raise.

@MainActor
final class CarnetNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CarnetNotifications()

    /// What a tapped notification opens: a conversation, or an entry shared
    /// with the member (`<collection>/<locale>/<slug>`).
    enum Tap { case conversation(String), entry(String) }

    /// Tapped a notification: what it opens and, for a remote push, the
    /// local id of the household it came from. On a cold start the tap
    /// arrives before the scene has wired this, so it is held until it is.
    var onOpen: ((Tap, String?) -> Void)? {
        didSet {
            guard let handler = onOpen, let p = pendingTap else { return }
            pendingTap = nil
            handler(p.tap, p.tag)
        }
    }
    private var pendingTap: (tap: Tap, tag: String?)?

    private func deliverTap(_ tap: Tap, tag: String?) {
        if let handler = onOpen { handler(tap, tag) } else { pendingTap = (tap, tag) }
    }
    /// The APNs token (hex) once the system granted it.
    private(set) var deviceToken: String?
    /// Called when the token arrives — the app uploads it to the households.
    var onDeviceToken: ((String) -> Void)?
    private var requested = false

    /// Ask once, then register. Safe to call on every sign-in.
    func requestAuthorizationOnce() {
        guard !requested else { return }
        requested = true
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// From the app delegate, with the raw APNs token.
    func setDeviceToken(_ token: String) {
        deviceToken = token
        onDeviceToken?(token)
    }

    /// Upload the token to every paired household the active member holds a
    /// session with, so each server can reach this phone — even while another
    /// household is the one on screen.
    func upload(_ token: String, session: CarnetSession) async {
        for h in session.households {
            guard let bearer = session.token(for: h) else { continue }
            do {
                try await DomainsAPI.registerDeviceToken(token, householdTag: h.id, baseURL: h.serverURL, bearer: bearer)
            } catch {
                print("[push] device-token upload failed for \(h.name): \(error.localizedDescription)")
            }
        }
    }

    // Banners even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // A tap opens the conversation, or the entry shared. The payload is the
    // server's: `conversationId` or `entry`, and `householdTag`, beside `aps`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let tap: Tap? = (info["conversationId"] as? String).map { .conversation($0) }
            ?? (info["entry"] as? String).map { .entry($0) }
        let tag = info["householdTag"] as? String
        Task { @MainActor in if let tap { CarnetNotifications.shared.deliverTap(tap, tag: tag) } }
        completionHandler()
    }
}

/// Where the app should go next, set from outside the view tree (a
/// notification tap) and consumed by the screen that owns the navigation.
@Observable
final class CarnetRouter {
    /// A conversation to open — pushed by the library's stack when set, then
    /// cleared.
    var openConversationId: String?
    /// An entry to open, as the list names it (`<collection>/<locale>/<slug>`)
    /// — set by a `carnet://entry/…` link, consumed by the list.
    var openEntryId: String?
}

// MARK: - App delegate (APNs registration callbacks)

final class CarnetAppDelegate: NSObject, UIApplicationDelegate {
    /// The notification-center delegate must be in place before launch ends,
    /// or the tap that launched the app is never delivered (Apple's rule).
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = CarnetNotifications.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in CarnetNotifications.shared.setDeviceToken(hex) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[push] registration failed: \(error.localizedDescription)")
    }
}
