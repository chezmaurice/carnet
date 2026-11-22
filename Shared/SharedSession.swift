import Foundation
import Security

/// The session the Maurice app and Carnet share on this iPhone or iPad
/// (CarnetApp/Services/SharedPairings.swift, the same file in both apps), as
/// much of it as Carnet's extensions need: where the household is, and who is
/// signed in.
///
/// The app folds the shared pairings into its own store when it runs. Until
/// then — Carnet just installed and never opened, the member signed in to
/// Maurice — its extensions found nobody, and « Save to Carnet » in Safari
/// asked for an address and a code as if it were a program of its own
/// (a first installation, 21 November 2026). They read the shared item
/// themselves now (CarnetAPI.baseURL / authToken), whenever Carnet's own store
/// holds no session; their entitlements list the shared Keychain group.
///
/// Read only: an extension never writes the shared pairings.
enum SharedSession {
    struct Session {
        let serverURL: String
        let token: String
        let household: String
        let memberId: String
        let memberName: String?
        let memberColor: String?
    }

    private struct Pairings: Decodable {
        struct Member: Decodable {
            let id: String
            let display_name: String
            let avatar_color: String?
        }
        struct Household: Decodable {
            let server: String
            let name: String
            let members: [Member]
            let active: String?
            let tokens: [String: String]
        }
        let households: [Household]
        let current: String?
    }

    /// The household on screen in whichever app wrote last, if someone is
    /// signed in there; else the first household someone is signed in to.
    static func read() -> Session? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "eu.chezmaurice.shared",
            kSecAttrAccount as String: "pairings",
            kSecAttrAccessGroup as String: "F5B4ZC8LEU.eu.chezmaurice.shared",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let pairings = try? JSONDecoder().decode(Pairings.self, from: data) else { return nil }

        func session(_ h: Pairings.Household) -> Session? {
            guard let active = h.active, let token = h.tokens[active], !token.isEmpty, !h.server.isEmpty else { return nil }
            let member = h.members.first { $0.id == active }
            return Session(serverURL: h.server, token: token, household: h.name, memberId: active,
                           memberName: member?.display_name, memberColor: member?.avatar_color)
        }
        if let current = pairings.households.first(where: { $0.server == pairings.current }), let s = session(current) {
            return s
        }
        return pairings.households.lazy.compactMap(session).first
    }
}
