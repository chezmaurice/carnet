import Foundation

/// The household's server, as dictation needs it: where it is and who is
/// asking. The composer builds one from the session, the share sheet from the
/// app group (ShareDictation); nil means "no server", and the device does what
/// it can on its own.
struct HouseholdTranscription: Sendable, Equatable {
    let baseURL: String
    let token: String
    /// The server first, even where the device has a recogniser of its own
    /// (Settings › Dictation; on unless the member turned it off).
    let preferred: Bool

    /// The dictation route, whatever the stored address ends with.
    private var endpoint: String {
        (baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL) + "/api/dictation"
    }

    /// What `GET /api/dictation` said, per server, for ten minutes. Asked
    /// only when the server is the candidate, so a device with SpeechAnalyzer
    /// never pays the round trip.
    @MainActor private static var known: [String: (available: Bool, local: Bool, at: Date)] = [:]
    @MainActor private static var unreachable: [String: Date] = [:]

    /// Whether this server transcribes, and whether it does so itself (the
    /// audio stays in the house) rather than through its provider. Nil when
    /// it could not be asked.
    @MainActor func capability() async -> (available: Bool, local: Bool)? {
        if let hit = Self.known[baseURL], Date().timeIntervalSince(hit.at) < 600 {
            return (hit.available, hit.local)
        }
        // A server that could not be asked is not asked again for a minute:
        // off the network, every tap would otherwise wait out the timeout.
        if let miss = Self.unreachable[baseURL], Date().timeIntervalSince(miss) < 60 { return nil }
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        struct Info: Decodable { let available: Bool; let engine: String? }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            Self.unreachable[baseURL] = Date()
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode
        // A server too old to have the route answers 404: that is a "no", and
        // worth remembering. Anything else is "couldn't ask".
        if status == 404 {
            Self.known[baseURL] = (false, false, Date())
            return (false, false)
        }
        guard status == 200, let info = try? JSONDecoder().decode(Info.self, from: data) else { return nil }
        Self.known[baseURL] = (info.available, info.engine == "local", Date())
        return (info.available, info.engine == "local")
    }

    /// Send a recorded clip; the text Whisper heard, or nil on any failure.
    /// No language goes with it: Whisper hears which one was spoken, where the
    /// app's would be the language its interface is read in — a phone set to
    /// English had French dictations translated into English.
    func transcribe(_ file: URL, seconds: TimeInterval) async -> String? {
        var components = URLComponents(string: endpoint)
        components?.queryItems = [URLQueryItem(name: "duration", value: String(format: "%.1f", seconds))]
        guard let url = components?.url else { return nil }
        // Longer than the server may take on its own (conversion, then up to
        // two minutes of Whisper), so a long clip is not abandoned here while
        // the server is still producing — and, through a provider, billing — it.
        var request = URLRequest(url: url, timeoutInterval: 240)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        struct Reply: Decodable { let text: String }
        guard let (data, response) = try? await URLSession.shared.upload(for: request, fromFile: file),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(Reply.self, from: data)
        else { return nil }
        return reply.text
    }
}
