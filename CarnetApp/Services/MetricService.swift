import Foundation

// MARK: - Metric service — fetches dashboard data from API

@Observable
final class MetricService {

    private(set) var metrics: [String: ResolvedMetric] = [:]
    private(set) var resolvedAt: Date?
    private(set) var isLoading = false

    /// The date for which metrics were last fetched.
    private var cachedDate: String?

    private static let cacheTTL: TimeInterval = 30 * 60 // 30 minutes

    /// Fetch dashboard data for a given date. Passing a new date invalidates the cache.
    func fetchDashboardData(layoutId: String, date: Date = Date(), refresh: Bool = false) async throws {
        let dateString = Self.dateFormatter.string(from: date)

        // Skip if cache is fresh and same date
        if !refresh,
           dateString == cachedDate,
           let resolvedAt,
           -resolvedAt.timeIntervalSinceNow < Self.cacheTTL,
           !metrics.isEmpty {
            return
        }

        isLoading = true
        defer { isLoading = false }

        var components = URLComponents(string: "\(CarnetAPI.baseURL)/api/v1/dashboard/\(layoutId)/data")!
        var queryItems: [URLQueryItem] = []
        queryItems.append(.init(name: "date", value: dateString))
        if refresh { queryItems.append(.init(name: "refresh", value: "1")) }
        components.queryItems = queryItems

        let url = components.url!
        let (data, response) = try await CarnetAPI.fetch(CarnetAPI.authorizedRequest(url: url))

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CarnetAPI.APIError.serverError(msg)
        }

        let decoded = try JSONDecoder().decode(DashboardDataResponse.self, from: data)
        metrics = decoded.metrics
        cachedDate = dateString

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        resolvedAt = formatter.date(from: decoded.resolved_at) ?? Date()
    }

    /// Look up a resolved metric by binding key (metric name, or metric.filterValue).
    func metric(for binding: WidgetDataBinding) -> ResolvedMetric? {
        let key = bindingKey(for: binding)
        return metrics[key]
    }

    /// Look up multiple bindings — returns array of heatmap entries for adherence.
    func heatmapRows(for bindings: [WidgetDataBinding]) -> [[Int]] {
        bindings.map { binding in
            let key = bindingKey(for: binding)
            guard let resolved = metrics[key],
                  case .heatmap(let entries) = resolved else {
                return Array(repeating: 0, count: 28)
            }
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            var countByDate: [String: Int] = [:]
            for entry in entries {
                countByDate[entry.date] = entry.count
            }
            return (0..<28).reversed().map { daysAgo in
                let date = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
                let key = Self.dateFormatter.string(from: date)
                return countByDate[key] ?? 0
            }
        }
    }

    private func bindingKey(for binding: WidgetDataBinding) -> String {
        if let filter = binding.filter, let firstValue = filter.values.first {
            return "\(binding.metric).\(firstValue)"
        }
        return binding.metric
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
