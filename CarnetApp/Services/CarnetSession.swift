import Foundation
import SwiftUI

/// A household this device is paired to — a server, the members enrolled there,
/// and which one is active. The device can hold several at once.
struct Household: Codable, Identifiable, Hashable {
    let id: String
    var serverURL: String
    var name: String
    var color: String? = nil
    var icon: String? = nil
    /// The household's public key, pinned the first time /api/health gives it:
    /// what lets the device follow the household to a new address.
    var key: String? = nil
    var deviceMembers: [CarnetAPI.Member]
    var activeMemberId: String?
}

/// Household session state for Carnet.
///
/// Mirrors Maurice's model: pair a device to one or more household servers, sign
/// in members, switch between them. Multi-household stays internal — the rest of
/// the app reads `serverURL` / `deviceMembers` / `activeMemberId`, which are now
/// projections onto the *current* household. Flat mirror keys are kept in the App
/// Group so `CarnetAPI` and the Share Extension keep posting as whoever is active.
@Observable
final class CarnetSession {
    private let defaults = UserDefaults(suiteName: CarnetAPI.appGroupID) ?? .standard

    /// Every household paired on this device.
    var households: [Household] = [] { didSet { saveHouseholds() } }

    /// Which household is currently active.
    var currentHouseholdId: String? {
        didSet {
            defaults.set(currentHouseholdId, forKey: Keys.currentHouseholdId)
            syncMirror()
            publishShared()
        }
    }

    // MARK: - Current-household projections

    private var currentIndex: Int? { households.firstIndex { $0.id == currentHouseholdId } }
    var currentHousehold: Household? { currentIndex.map { households[$0] } }
    var currentHouseholdName: String { currentHousehold?.name ?? "Household" }

    /// The active member's chosen language (`AppLanguage.chosen`), observed so
    /// the interface is redrawn in it when it is learnt or changes.
    private(set) var language: String? = AppLanguage.chosen

    private func mutateCurrent(_ f: (inout Household) -> Void) {
        guard let i = currentIndex else { return }
        f(&households[i])   // mutating the array triggers didSet → persist
    }

    var serverURL: String? {
        get { currentHousehold?.serverURL }
        set {
            guard let v = newValue else { return }
            if currentHousehold != nil { mutateCurrent { $0.serverURL = v }; syncMirror() }
            else { _ = pair(serverURL: v) }
        }
    }

    var deviceMembers: [CarnetAPI.Member] {
        get { currentHousehold?.deviceMembers ?? [] }
        set { mutateCurrent { $0.deviceMembers = newValue } }
    }

    var activeMemberId: String? {
        get { currentHousehold?.activeMemberId }
        set { mutateCurrent { $0.activeMemberId = newValue }; syncMirror() }
    }

    var isPaired: Bool { currentHousehold != nil }
    var hasActiveSession: Bool { activeMemberId != nil && tokenForActiveMember != nil }
    var tokenForActiveMember: String? { activeMemberId.flatMap { tokenForMember($0) } }

    var activeMember: CarnetAPI.Member? {
        guard let id = activeMemberId else { return nil }
        return deviceMembers.first { $0.id == id }
    }

    /// The active member's session was refused (401) and they are back at
    /// the member picker; it says why, once.
    var sessionEnded = false

    /// An invitation received and not yet used (a scan, a link, a code typed
    /// on the welcome screen). « Who's here? » picks it up and enrolls with it.
    var pendingInvitation: Invitation?

    /// Take an invitation from a scan or a link: select its household
    /// (pairing it if this device has never seen it), go to « Who's here? »
    /// and leave the code there to be used. Same as the Maurice app.
    func receive(_ invitation: Invitation) {
        pair(serverURL: invitation.server)
        sessionEnded = false
        activeMemberId = nil
        pendingInvitation = invitation
    }

    init() {
        TokenVault.migrateFromDefaults()
        loadHouseholds()
        migrateLegacyIfNeeded()
        currentHouseholdId = defaults.string(forKey: Keys.currentHouseholdId) ?? households.first?.id
        syncMirror()
        MemberStore.migrateLegacy()
        // Sessions never expire: a 401 on a request that carried a token means
        // it was revoked or its member removed.
        NotificationCenter.default.addObserver(forName: .carnetSessionRejected, object: nil, queue: .main) { [weak self] note in
            guard let token = note.userInfo?["token"] as? String else { return }
            self?.sessionRejected(token: token)
        }
        joinShared()
        SharedPairings.observe { [weak self] in self?.applyShared() }
    }

    /// A request carrying `token` was answered 401: forget that token wherever
    /// it is stored. If it was the active member's, the household goes back to
    /// its member picker.
    func sessionRejected(token: String) {
        for h in households {
            for m in h.deviceMembers where TokenVault.get(Self.tokenKey(h.id, m.id)) == token {
                TokenVault.remove(Self.tokenKey(h.id, m.id))
                TokenVault.remove(Self.mcpKey(h.id, m.id))
                // The share extension's copy (syncMirror) goes with it.
                if TokenVault.get("carnet.token.\(m.id)") == token { TokenVault.remove("carnet.token.\(m.id)") }
                MemberStore.purge(server: h.serverURL, member: m.id)
                if h.activeMemberId == m.id {
                    updateHousehold(id: h.id) { $0.activeMemberId = nil }
                    if h.id == currentHouseholdId { sessionEnded = true }
                }
            }
        }
        syncMirror()
        publishShared()
    }

    // MARK: - Households

    /// Pair (or re-select) a household by server URL; returns its local id.
    @discardableResult
    func pair(serverURL: String, name: String? = nil) -> String {
        if let existing = households.first(where: { $0.serverURL == serverURL }) {
            currentHouseholdId = existing.id
            return existing.id
        }
        let h = Household(
            id: UUID().uuidString,
            serverURL: serverURL,
            name: (name?.isEmpty == false) ? name! : Self.defaultName(serverURL),
            deviceMembers: [],
            activeMemberId: nil
        )
        households.append(h)
        currentHouseholdId = h.id
        return h.id
    }

    func switchHousehold(_ id: String) {
        guard households.contains(where: { $0.id == id }) else { return }
        currentHouseholdId = id
    }

    func updateHousehold(id: String, _ f: (inout Household) -> Void) {
        guard let i = households.firstIndex(where: { $0.id == id }) else { return }
        f(&households[i])
    }

    /// Remove (disconnect) the current household + its tokens, falling back to
    /// another household, or fully unpaired if it was the last.
    func unpair() {
        guard let hid = currentHouseholdId else { return }
        for member in deviceMembers {
            // Each session held here is closed on the server, not only erased.
            if let url = serverURL, let token = tokenForMember(member.id) {
                SessionClosures.shared.close(server: url, token: token)
            }
            removeToken(for: member.id)
            TokenVault.remove(Self.mcpKey(hid, member.id))
            if let url = serverURL { MemberStore.purge(server: url, member: member.id) }
        }
        households.removeAll { $0.id == hid }
        currentHouseholdId = households.first?.id
    }

    // MARK: - Member sessions (scoped to the current household)

    /// Bring the members kept on this device up to date with the household's
    /// roster: a name, a colour or a picture changed elsewhere — and a member
    /// signed in before pictures were read has none on record.
    func refreshMembers() async {
        guard let roster = try? await CarnetAPI.listMembers() else { return }
        var byId: [String: CarnetAPI.Member] = [:]
        for member in roster { byId[member.id] = member }
        let updated = deviceMembers.map { byId[$0.id] ?? $0 }
        if updated != deviceMembers { deviceMembers = updated }
    }

    /// The language the active member chose in Maurice, read again from the
    /// household; kept as it was when the server cannot say.
    func refreshLanguage() async {
        guard let id = activeMemberId, let token = tokenForMember(id),
              let chosen = try? await CarnetAPI.chosenLocale(token: token) else { return }
        AppLanguage.set(chosen, for: id)
        if language != AppLanguage.chosen { language = AppLanguage.chosen }
    }

    /// Each household's own name, colour and icon (`/api/health`): a household
    /// paired by its address is shown by its name once the server gives one.
    func refreshHouseholdIdentities() async {
        let snapshot = households.map { ($0.id, $0.serverURL, $0.key) }
        let found = await withTaskGroup(of: (String, CarnetAPI.HealthResponse?, String?).self) { group in
            for (id, url, key) in snapshot {
                group.addTask {
                    if let health = try? await CarnetAPI.health(at: url) { return (id, health, nil) }
                    // Silent at its address: has it moved? Only a household
                    // whose key this device holds can be followed.
                    guard let key, let target = await HouseholdMove.follow(from: url, key: key) else { return (id, nil, nil) }
                    return (id, try? await CarnetAPI.health(at: target), target)
                }
            }
            var all: [(String, CarnetAPI.HealthResponse?, String?)] = []
            for await result in group { all.append(result) }
            return all
        }
        for (id, health, movedTo) in found {
            guard let i = households.firstIndex(where: { $0.id == id }) else { continue }
            var h = households[i]
            // Same household, new address: its id, members and tokens stay.
            if let movedTo { h.serverURL = movedTo }
            if let health {
                if let name = health.household?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { h.name = name }
                h.color = health.household_color
                h.icon = health.household_icon
                // Pin once; a different key later is not this household.
                if h.key == nil, let k = health.identity_key { h.key = k }
            }
            if h != households[i] { households[i] = h }
            if movedTo != nil, id == currentHouseholdId { syncMirror() }
        }
    }

    func loginMember(_ id: String, token: String) {
        sessionEnded = false
        storeToken(token, for: id)
        activeMemberId = id
    }

    /// Switch to a member who already has a cached token. Returns false if none.
    func switchToMember(_ id: String) -> Bool {
        guard tokenForMember(id) != nil else { return false }
        sessionEnded = false
        activeMemberId = id
        return true
    }

    /// Sign a member out of this device: their session is closed on the
    /// server (`SessionClosures` — at once, or when the network is back) and
    /// what the device kept for them goes.
    func logoutMember(_ id: String) {
        if let url = serverURL, let token = tokenForMember(id) {
            SessionClosures.shared.close(server: url, token: token)
        }
        if let token = tokenForMember(id), TokenVault.get("carnet.token.\(id)") == token {
            TokenVault.remove("carnet.token.\(id)")
        }
        removeToken(for: id)
        if let url = serverURL { MemberStore.purge(server: url, member: id) }
        if activeMemberId == id { activeMemberId = nil }
    }

    func updateDeviceMembers(_ members: [CarnetAPI.Member]) {
        deviceMembers = members
    }

    // MARK: - Token storage (per household + member, Keychain shared with the extension)

    static func tokenKey(_ householdId: String, _ memberId: String) -> String { "carnet.token.\(householdId).\(memberId)" }
    /// The member's `maur_` API token, for signed-in links to the web garden.
    static func mcpKey(_ householdId: String, _ memberId: String) -> String { "carnet.mcp-token.\(householdId).\(memberId)" }

    private func tokenKey(_ id: String) -> String? {
        currentHouseholdId.map { Self.tokenKey($0, id) }
    }

    func tokenForMember(_ id: String) -> String? {
        tokenKey(id).flatMap(TokenVault.get)
    }

    /// The session of a member of any household on this device — what an
    /// offline capture is sent with (SyncService).
    func token(householdId: String, memberId: String) -> String? {
        TokenVault.get(Self.tokenKey(householdId, memberId))
    }

    /// The session of a household's active member, whichever household is
    /// on screen — what the push registration needs to reach every server.
    func token(for household: Household) -> String? {
        guard let member = household.activeMemberId else { return nil }
        return TokenVault.get(Self.tokenKey(household.id, member))
    }

    private func storeToken(_ token: String, for id: String) {
        guard let k = tokenKey(id) else { return }
        TokenVault.set(token, k)
        syncMirror()
        publishShared()
    }

    private func removeToken(for id: String) {
        guard let k = tokenKey(id) else { return }
        TokenVault.remove(k)
        syncMirror()
        publishShared()
    }

    // MARK: - Flat mirror (read by CarnetAPI + the Share Extension)

    /// Keep the legacy flat keys pointing at the current household's active member
    /// so `CarnetAPI.baseURL` / `CarnetAPI.authToken` resolve without knowing about
    /// households. This is what lets the Share Extension post as whoever is active.
    private func syncMirror() {
        if let url = currentHousehold?.serverURL { CarnetAPI.baseURL = url }
        defaults.set(activeMemberId, forKey: Keys.activeMemberId)
        if language != AppLanguage.chosen { language = AppLanguage.chosen }
        if let id = activeMemberId, let token = tokenForMember(id) {
            TokenVault.set(token, "carnet.token.\(id)")
        } else if let id = activeMemberId {
            TokenVault.remove("carnet.token.\(id)")
        }
    }

    // MARK: - Persistence

    private func saveHouseholds() {
        if let data = try? JSONEncoder().encode(households) {
            defaults.set(data, forKey: Keys.households)
        }
        publishShared()
    }

    // MARK: - Shared with the Maurice app (SharedPairings)

    /// What the two apps last agreed on, as this one knows it.
    @ObservationIgnored private var sharedSeen: SharedPairings?
    /// Set while the Maurice app's pairings are being applied here, so that
    /// applying them does not write them back — and until `init` has read
    /// them, so that loading this app's own copy does not overwrite a newer one.
    @ObservationIgnored private var applyingShared = true
    @ObservationIgnored private var sharedJoined = (UserDefaults(suiteName: CarnetAPI.appGroupID) ?? .standard).bool(forKey: Keys.sharedJoined)

    /// These households, members and sessions, as the Maurice app is to see them.
    private var sharedSnapshot: SharedPairings {
        SharedPairings(households: households.map { h in
            var tokens: [String: String] = [:]
            for m in h.deviceMembers { tokens[m.id] = TokenVault.get(Self.tokenKey(h.id, m.id)) }
            return .init(server: h.serverURL, key: h.key, name: h.name, color: h.color, icon: h.icon,
                         members: h.deviceMembers.map {
                             .init(id: $0.id, display_name: $0.display_name, avatar_color: $0.avatar_color, has_pin: $0.has_pin,
                                   role: $0.role, avatar_url: $0.avatar_url, username: $0.username)
                         },
                         active: h.activeMemberId, tokens: tokens)
        }, current: currentHousehold?.serverURL)
    }

    /// The first launch after the update: what each app held becomes what both
    /// hold. Afterwards, what is shared is what counts.
    private func joinShared() {
        applyingShared = false
        if !sharedJoined {
            var shared = sharedSnapshot
            if let theirs = SharedPairings.read() { shared.absorb(theirs) }
            shared.write()
            sharedJoined = true
            defaults.set(true, forKey: Keys.sharedJoined)
        }
        applyShared()
    }

    /// Something changed here: the Maurice app hears of it.
    private func publishShared() {
        guard sharedJoined, !applyingShared else { return }
        let snapshot = sharedSnapshot
        guard snapshot != sharedSeen else { return }
        snapshot.write()
        sharedSeen = snapshot
    }

    /// The Maurice app may have changed something: take it as it is, in place.
    func applyShared() {
        guard sharedJoined, let shared = SharedPairings.read(), shared != sharedSeen else { return }
        sharedSeen = shared
        applyingShared = true
        defer { applyingShared = false }
        /// A member whose session is gone from here: as `logoutMember` leaves them.
        func forget(_ hid: String, _ server: String, _ member: String) {
            let token = TokenVault.get(Self.tokenKey(hid, member))
            if let token, TokenVault.get("carnet.token.\(member)") == token { TokenVault.remove("carnet.token.\(member)") }
            TokenVault.remove(Self.tokenKey(hid, member))
            TokenVault.remove(Self.mcpKey(hid, member))
            if token != nil { MemberStore.purge(server: server, member: member) }
        }
        var next: [Household] = []
        for s in shared.households {
            let local = households.first { s.same(server: $0.serverURL, key: $0.key) }
            let hid = local?.id ?? UUID().uuidString
            let known = Dictionary((local?.deviceMembers ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let members = s.members.map { m in
                CarnetAPI.Member(id: m.id, display_name: m.display_name, avatar_color: m.avatar_color, has_pin: m.has_pin,
                                 role: m.role, username: m.username ?? known[m.id]?.username, avatar_url: m.avatar_url)
            }
            for m in members {
                let k = Self.tokenKey(hid, m.id)
                if let t = s.tokens[m.id] {
                    if TokenVault.get(k) != t { TokenVault.set(t, k) }
                } else {
                    forget(hid, s.server, m.id)
                }
            }
            for m in local?.deviceMembers ?? [] where !members.contains(where: { $0.id == m.id }) {
                forget(hid, s.server, m.id)
            }
            next.append(Household(id: hid, serverURL: s.server, name: s.name, color: s.color, icon: s.icon,
                                  key: s.key ?? local?.key, deviceMembers: members, activeMemberId: s.active))
        }
        for gone in households where !next.contains(where: { $0.id == gone.id }) {
            for m in gone.deviceMembers { forget(gone.id, gone.serverURL, m.id) }
        }
        if next != households { households = next }
        let current = next.first { $0.serverURL == shared.current }?.id ?? next.first?.id
        if currentHouseholdId != current { currentHouseholdId = current }
        if hasActiveSession { sessionEnded = false }
        syncMirror()
    }

    private func loadHouseholds() {
        guard let data = defaults.data(forKey: Keys.households),
              let hs = try? JSONDecoder().decode([Household].self, from: data) else { return }
        households = hs
    }

    /// One-time upgrade of the pre-multi-household state into a single household.
    private func migrateLegacyIfNeeded() {
        guard households.isEmpty,
              let url = defaults.string(forKey: Keys.legacyServerURL) else { return }
        var members: [CarnetAPI.Member] = []
        if let data = defaults.data(forKey: Keys.legacyDeviceMembers),
           let decoded = try? JSONDecoder().decode([CarnetAPI.Member].self, from: data) {
            members = decoded
        }
        let activeId = defaults.string(forKey: Keys.activeMemberId)
        let hid = UUID().uuidString
        for m in members {
            if let t = TokenVault.get("carnet.token.\(m.id)") {
                TokenVault.set(t, Self.tokenKey(hid, m.id))
            }
        }
        households = [Household(id: hid, serverURL: url, name: Self.defaultName(url),
                                deviceMembers: members, activeMemberId: activeId)]
        defaults.set(hid, forKey: Keys.currentHouseholdId)
        defaults.removeObject(forKey: Keys.legacyServerURL)
    }

    static func defaultName(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }

    private enum Keys {
        static let households = "carnet.households"
        static let currentHouseholdId = "carnet.currentHouseholdId"
        static let activeMemberId = "carnet.activeMemberId"
        static let legacyServerURL = "carnet.serverURL"
        static let legacyDeviceMembers = "carnet.deviceMembers"
        static let sharedJoined = "carnet.shared.joined"
    }
}

#if DEBUG
extension CarnetSession {
    /// Seed two households with members for offline UI verification.
    func seedSamples() {
        let ha = CarnetAPI.Member(id: "ha", display_name: "Hana", avatar_color: "#5a735a", has_pin: false, role: "admin")
        let th = CarnetAPI.Member(id: "th", display_name: "Théo", avatar_color: "#7a5a73", has_pin: true, role: "member")
        let me = CarnetAPI.Member(id: "me", display_name: "Mei", avatar_color: "#5a6a7a", has_pin: false, role: "member")
        households = [
            Household(id: "h1", serverURL: "https://home.example", name: "home.example",
                      deviceMembers: [ha, th, me], activeMemberId: "ha"),
            Household(id: "h2", serverURL: "https://demo.local", name: "demo.local",
                      deviceMembers: [ha], activeMemberId: "ha"),
        ]
        TokenVault.set("token-ha", "carnet.token.h1.ha")
        currentHouseholdId = "h1"
    }
}
#endif

// MARK: - Avatar color

extension CarnetAPI.Member {
    var color: Color {
        let hex = avatar_color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    var initial: String { String(display_name.prefix(1)) }

    /// Where the member's picture is fetched from, when they have one.
    var avatarImageURL: URL? {
        guard let avatar_url, !avatar_url.isEmpty else { return nil }
        return URL(string: avatar_url.hasPrefix("http") ? avatar_url : CarnetAPI.baseURL + avatar_url)
    }
}
