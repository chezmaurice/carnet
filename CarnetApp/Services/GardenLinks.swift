import Foundation

/// Builds the outbound links a garden item can open: its page on the garden
/// website, and its markdown file in an editor holding the same git checkout —
/// Working Copy on iOS, Obsidian where the vault is synced.
enum GardenLinks {
    /// Written by the old Settings screen only; nothing reads it any more —
    /// the garden is served by the household's server itself.
    static let webURLKey = "carnet.garden.webURL"
    static let workingCopyRepoKey = "carnet.garden.workingCopyRepo"
    static let obsidianVaultKey = "carnet.garden.obsidianVault"

    private static var defaults: UserDefaults { CarnetAPI.defaults }

    /// The repo name as it appears in Working Copy. Empty = use the garden's
    /// username (the checkout is usually cloned under that name).
    static func workingCopyRepo(fallback: String) -> String {
        let stored = defaults.string(forKey: workingCopyRepoKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return stored.isEmpty ? fallback : stored
    }

    /// The Obsidian vault holding the garden checkout. Empty = the username.
    static func obsidianVault(fallback: String) -> String {
        let stored = defaults.string(forKey: obsidianVaultKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return stored.isEmpty ? fallback : stored
    }

    // MARK: - URL builders

    /// A page on the garden website (`web_path` is site-relative, /g/…),
    /// opened signed in: the garden is members-only, so the link goes through
    /// `/login?token=<maur_>&to=<path>`, as in the Maurice app. Without a
    /// token (offline, refused) it is the bare page, which asks to sign in.
    static func webURL(_ path: String) async -> URL? {
        let base = CarnetAPI.baseURL
        guard !base.isEmpty, path.hasPrefix("/") else { return nil }
        guard let token = await webToken() else { return URL(string: base + path) }
        let bare = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let to = path.addingPercentEncoding(withAllowedCharacters: bare) ?? path
        let t = token.addingPercentEncoding(withAllowedCharacters: bare) ?? token
        return URL(string: "\(base)/login?token=\(t)&to=\(to)")
    }

    /// The active member's `maur_` API token, fetched once and kept in the
    /// Keychain: the server hands back the same one unless asked to rotate.
    private static func webToken() async -> String? {
        guard let hid = defaults.string(forKey: "carnet.currentHouseholdId"),
              let mid = defaults.string(forKey: "carnet.activeMemberId") else { return nil }
        let key = CarnetSession.mcpKey(hid, mid)
        if let cached = TokenVault.get(key) { return cached }
        guard let fresh = try? await CarnetAPI.mcpToken() else { return nil }
        TokenVault.set(fresh, key)
        return fresh
    }

    /// Open the file in Working Copy (x-callback scheme; `file` is repo-relative).
    static func workingCopyURL(file: String, username: String) -> URL? {
        var comps = URLComponents(string: "working-copy://x-callback-url/open")!
        comps.queryItems = [
            URLQueryItem(name: "repo", value: workingCopyRepo(fallback: username)),
            URLQueryItem(name: "path", value: file),
        ]
        return comps.url
    }

    /// Open the file in Obsidian. Obsidian addresses notes without the .md
    /// extension; other files keep theirs.
    static func obsidianURL(file: String, username: String) -> URL? {
        let noExt = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
        var comps = URLComponents(string: "obsidian://open")!
        comps.queryItems = [
            URLQueryItem(name: "vault", value: obsidianVault(fallback: username)),
            URLQueryItem(name: "file", value: noExt),
        ]
        return comps.url
    }
}
