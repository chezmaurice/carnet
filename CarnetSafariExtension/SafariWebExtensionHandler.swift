import Foundation
import SafariServices

/// The native half of the Safari extension on iPhone and iPad. The web half is
/// Maurice's (maurice-ios/web-clipper, copied into Resources/ by
/// scripts/sync-web-clipper.sh), the same code as in Chrome and Firefox. Its
/// popup asks one thing, `{type: "session"}`, and is answered with whoever is
/// signed in to Carnet, read from the app group as the share extension reads
/// it — or, when Carnet has not been opened yet, with whoever is signed in to
/// the Maurice app on this device (Shared/SharedSession.swift). The answer
/// always names the app and the address that opens it: with no one signed in
/// anywhere it holds nothing else, and the popup says so and sends the member
/// to the app. It never asks for an address and a code in Safari.
///
/// The popup can only ask because the manifest lists `nativeMessaging`:
/// without that permission Safari leaves `sendNativeMessage` out, and the
/// extension took every device for one where nobody was signed in (until
/// extension 2.0.9; scripts/sync-web-clipper.sh now refuses a manifest
/// without it).
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        var reply: [String: Any] = ["app": "Carnet", "openUrl": "carnet://"]
        if message?["type"] as? String == "session",
           !CarnetAPI.baseURL.isEmpty, let token = CarnetAPI.authToken {
            reply["serverUrl"] = CarnetAPI.baseURL
            reply["token"] = token
            if CarnetAPI.hasOwnSession, let household = Self.currentHousehold() {
                reply["household"] = household.name
                if let member = household.deviceMembers.first(where: { $0.id == household.activeMemberId }) {
                    var who: [String: Any] = ["name": member.display_name]
                    if let color = member.avatar_color { who["color"] = color }
                    reply["member"] = who
                }
            } else if !CarnetAPI.hasOwnSession, let shared = SharedSession.read() {
                // Carnet not opened yet: the session is the one shared with
                // the Maurice app (Shared/SharedSession.swift).
                reply["household"] = shared.household
                if let name = shared.memberName {
                    var who: [String: Any] = ["name": name]
                    if let color = shared.memberColor { who["color"] = color }
                    reply["member"] = who
                }
            }
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    /// The household CarnetSession keeps current, as much of it as the popup
    /// shows: its name and who is signed in.
    private struct Household: Decodable {
        struct Member: Decodable {
            let id: String
            let display_name: String
            let avatar_color: String?
        }
        let id: String
        let name: String
        let deviceMembers: [Member]
        let activeMemberId: String?
    }

    private static func currentHousehold() -> Household? {
        let defaults = CarnetAPI.defaults
        guard let data = defaults.data(forKey: "carnet.households"),
              let all = try? JSONDecoder().decode([Household].self, from: data) else { return nil }
        let current = defaults.string(forKey: "carnet.currentHouseholdId")
        return all.first { $0.id == current } ?? all.first
    }
}
