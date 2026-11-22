import Foundation

@Observable
final class LayoutService {
    private(set) var summaries: [LayoutSummary] = []
    private var cache: [String: LayoutSpec] = [:]
    private var cacheVersions: [String: Int] = [:]

    func fetchList(activeOnly: Bool = true) async throws -> [LayoutSummary] {
        var urlString = "\(CarnetAPI.baseURL)/api/v1/layouts"
        if activeOnly { urlString += "?active_only=1" }

        let url = URL(string: urlString)!
        let (data, response) = try await CarnetAPI.fetch(CarnetAPI.authorizedRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CarnetAPI.APIError.serverError(String(data: data, encoding: .utf8) ?? "")
        }

        let list: [LayoutSummary]
        do {
            list = try JSONDecoder().decode([LayoutSummary].self, from: data)
        } catch {
            print("[LayoutService] fetchList decode error: \(error)")
            throw error
        }
        summaries = list
        return list
    }

    func fetchSpec(id: String) async throws -> LayoutSpec {
        // Check cache — return if version matches
        if let cached = cache[id],
           let summaryVersion = summaries.first(where: { $0.id == id })?.version,
           cached.version == summaryVersion {
            return cached
        }

        let url = URL(string: "\(CarnetAPI.baseURL)/api/v1/layouts/\(id)")!
        let (data, response) = try await CarnetAPI.fetch(CarnetAPI.authorizedRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CarnetAPI.APIError.serverError(String(data: data, encoding: .utf8) ?? "")
        }

        let spec: LayoutSpec
        do {
            spec = try JSONDecoder().decode(LayoutSpec.self, from: data)
        } catch {
            print("[LayoutService] fetchSpec decode error: \(error)")
            if let raw = String(data: data, encoding: .utf8) {
                print("[LayoutService] raw JSON (first 500 chars): \(String(raw.prefix(500)))")
            }
            throw error
        }
        cache[id] = spec
        cacheVersions[id] = spec.version
        return spec
    }
}
