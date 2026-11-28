import Foundation
import Observation

/// A provider outside the house that a member's data can reach, as
/// `GET /api/me/ai-consent` names it.
struct AIProvider: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    /// ISO region code of where it processes, and a city when known.
    let region: String?
    let city: String?

    /// "Paris, France" in the member's language, or nil when unknown.
    var place: String? {
        let country = region.flatMap { AppLanguage.locale.localizedString(forRegionCode: $0) }
        switch (city, country) {
        case let (city?, country?): return "\(city), \(country)"
        case let (nil, country?): return country
        case let (city?, nil): return city
        default: return nil
        }
    }
}

struct AIConsentRecord: Decodable, Equatable {
    let status: String
    let providers: [String]
    let decided_at: String
}

struct AIConsentState: Decodable {
    let record: AIConsentRecord?
    let providers: [AIProvider]
    let needs_answer: Bool
    let uncovered: [String]
}

/// Consent to send what the member gives Maurice to AI providers. The server
/// holds the answer and the rule (maurice-server, services/aiConsent.ts): a
/// member with no answer on file is refused an outside provider like one who
/// said no. So Carnet asks, as the Maurice app does and with the same words:
/// after sign-in, until the member answers, and again when a provider appears
/// that their yes does not cover. The answer is the member's, not the app's —
/// one given in the Maurice app is the one read here.
@Observable @MainActor
final class AIConsentStore {
    private(set) var state: AIConsentState?
    /// Whether the last refresh got an answer from the server for `owner`.
    private(set) var loaded = false
    /// The household and member `state` belongs to.
    private var owner: String?

    var record: AIConsentRecord? { state?.record }
    var providers: [AIProvider] { state?.providers ?? [] }
    var declined: Bool { record?.status == "declined" }
    /// The question is owed: no answer yet, or a yes that does not cover a
    /// provider in use. Never while the server could not be asked.
    var needsAnswer: Bool { loaded && state?.needs_answer == true }
    /// Providers that appeared since the member's last yes.
    var newProviders: [AIProvider] {
        guard let state else { return [] }
        return state.providers.filter { state.uncovered.contains($0.id) }
    }

    init() {
        // A request was refused for want of consent (CarnetAPI.fetch): read
        // the answer again — if none is on file, the question comes up.
        NotificationCenter.default.addObserver(forName: .carnetAIConsentRequired, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private static var endpoint: URL? { URL(string: "\(CarnetAPI.baseURL)/api/me/ai-consent") }
    private static var currentOwner: String? {
        guard !CarnetAPI.baseURL.isEmpty, let member = CarnetAPI.activeMemberId else { return nil }
        return "\(CarnetAPI.baseURL)#\(member)"
    }

    /// Read the active member's answer from their household.
    func refresh() async {
        guard let who = Self.currentOwner, let url = Self.endpoint, let token = CarnetAPI.authToken else {
            state = nil; loaded = false; owner = nil
            return
        }
        // Another member's answer is not this one's.
        if owner != who { state = nil; loaded = false; owner = who }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await CarnetAPI.fetch(request),
              let status = (response as? HTTPURLResponse)?.statusCode,
              Self.currentOwner == who else { return } // unreachable: keep what we had
        if status == 200, let s = try? JSONDecoder().decode(AIConsentState.self, from: data) {
            state = s
            loaded = true
        } else if status == 404 {
            // A server from before the route: it holds no rule to answer to.
            state = nil
            loaded = true
        }
    }

    /// Accept (every provider shown, plus any already accepted) or decline.
    /// False when the answer could not be recorded.
    func decide(accept: Bool) async -> Bool {
        guard let who = Self.currentOwner, let url = Self.endpoint, let token = CarnetAPI.authToken else { return false }
        let ids = Set(providers.map(\.id)).union(record?.providers ?? []).sorted()
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "status": accept ? "accepted" : "declined", "providers": ids,
        ] as [String: Any])
        guard let (data, response) = try? await CarnetAPI.fetch(request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let s = try? JSONDecoder().decode(AIConsentState.self, from: data),
              Self.currentOwner == who else { return false }
        state = s
        loaded = true
        owner = who
        return true
    }

    #if DEBUG
    /// The screen on made-up providers, with no household: launch with
    /// `-AIConsentGallery` (how its layout gets checked on a simulator).
    static var galleryRequested: Bool { ProcessInfo.processInfo.arguments.contains("-AIConsentGallery") }
    func seedSample() {
        state = AIConsentState(
            record: AIConsentRecord(status: "accepted", providers: ["scaleway"], decided_at: "2026-01-01 09:00:00"),
            providers: [AIProvider(id: "scaleway", name: "Scaleway Generative APIs", region: "FR", city: "Paris"),
                        AIProvider(id: "staan", name: "Staan (web search)", region: "FR", city: nil)],
            needs_answer: true, uncovered: ["staan"])
        loaded = true
    }
    #endif

    /// What to say in place of a server's refusal for want of consent, or nil
    /// when the answer is about something else.
    nonisolated static func refusalMessage(_ data: Data, status: Int) -> String? {
        CarnetAPI.isConsentRefusal(data, status: status) ? L("ai.consent.carnet.refused") : nil
    }
}
