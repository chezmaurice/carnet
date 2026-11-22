import Foundation

// MARK: - Full layout spec (from GET /api/v1/layouts/:id)

struct LayoutSpec: Codable, Identifiable {
    let id: String
    let version: Int
    let title: String
    let cadence: String
    let active_from: String?
    let active_until: String?
    let spec: LayoutBody
    let created_at: String?
    let updated_at: String?
}

struct LayoutBody: Codable {
    let description: String?
    let rows: [LayoutRow]

    // The spec JSON embeds top-level fields (id, version, title, cadence, etc.)
    // alongside rows. We only care about description + rows here.
    enum CodingKeys: String, CodingKey {
        case description, rows
    }
}

struct LayoutRow: Codable, Identifiable {
    let id: String
    let columns: Int
    let widgets: [WidgetSpec]
    let section: String?
}

struct WidgetSpec: Codable, Identifiable {
    let id: String
    let type: String
    let span: Int?
    let data: WidgetData
    let params: [String: AnyCodable]?

    var effectiveSpan: Int { span ?? 1 }
}

// MARK: - Widget data binding

/// `data` can be a single object or an array (e.g. adherence_heatmap).
enum WidgetData: Codable {
    case single(WidgetDataBinding)
    case multi([WidgetDataBinding])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let arr = try? container.decode([WidgetDataBinding].self) {
            self = .multi(arr)
        } else {
            let obj = try container.decode(WidgetDataBinding.self)
            self = .single(obj)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let binding):
            try container.encode(binding)
        case .multi(let bindings):
            try container.encode(bindings)
        }
    }
}

struct WidgetDataBinding: Codable {
    let metric: String
    let period: String
    let aggregation: String?
    let field: String?
    let filter: [String: String]?
    let label: String?
    let goal_per_day: Double?
}

// MARK: - Dashboard data response (from GET /api/v1/dashboard/:id/data)

struct DashboardDataResponse: Codable {
    let layout_id: String
    let layout_version: Int
    let resolved_at: String
    let metrics: [String: ResolvedMetric]
}

struct SeriesPoint: Codable {
    let date: String
    let value: Double
}

struct MealEntryResponse: Codable, Identifiable {
    var id: String { time }
    let time: String
    let meal_type: String
    let description: String
}

struct HabitHeatmap: Codable {
    let entries: [HeatmapEntry]
}

struct HeatmapEntry: Codable {
    let date: String
    let count: Int
}

struct ScalarGroupItem: Codable {
    let label: String
    let value: Double
    let unit: String
}

enum ResolvedMetric: Codable {
    case scalar(value: Double?, unit: String?)
    case series(points: [SeriesPoint])
    case sleepStages(core_h: Double, rem_h: Double, deep_h: Double, awake_h: Double, total_h: Double)
    case count(value: Int)
    case meals(entries: [MealEntryResponse])
    case heatmap(entries: [HeatmapEntry])
    case scalarGroup(items: [ScalarGroupItem])

    private enum CodingKeys: String, CodingKey {
        case type
        case value, unit, points
        case core_h, rem_h, deep_h, awake_h, total_h
        case entries, items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "scalar":
            let value = try container.decodeIfPresent(Double.self, forKey: .value)
            let unit = try container.decodeIfPresent(String.self, forKey: .unit)
            self = .scalar(value: value, unit: unit)

        case "series":
            let points = try container.decode([SeriesPoint].self, forKey: .points)
            self = .series(points: points)

        case "sleep_stages":
            let core = try container.decode(Double.self, forKey: .core_h)
            let rem = try container.decode(Double.self, forKey: .rem_h)
            let deep = try container.decode(Double.self, forKey: .deep_h)
            let awake = try container.decode(Double.self, forKey: .awake_h)
            let total = try container.decode(Double.self, forKey: .total_h)
            self = .sleepStages(core_h: core, rem_h: rem, deep_h: deep, awake_h: awake, total_h: total)

        case "count":
            let value = try container.decode(Int.self, forKey: .value)
            self = .count(value: value)

        case "meals":
            let entries = try container.decode([MealEntryResponse].self, forKey: .entries)
            self = .meals(entries: entries)

        case "heatmap":
            let entries = try container.decode([HeatmapEntry].self, forKey: .entries)
            self = .heatmap(entries: entries)

        case "scalar_group":
            let items = try container.decode([ScalarGroupItem].self, forKey: .items)
            self = .scalarGroup(items: items)

        default:
            self = .scalar(value: nil, unit: nil)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .scalar(let value, let unit):
            try container.encode("scalar", forKey: .type)
            try container.encodeIfPresent(value, forKey: .value)
            try container.encodeIfPresent(unit, forKey: .unit)
        case .series(let points):
            try container.encode("series", forKey: .type)
            try container.encode(points, forKey: .points)
        case .sleepStages(let core, let rem, let deep, let awake, let total):
            try container.encode("sleep_stages", forKey: .type)
            try container.encode(core, forKey: .core_h)
            try container.encode(rem, forKey: .rem_h)
            try container.encode(deep, forKey: .deep_h)
            try container.encode(awake, forKey: .awake_h)
            try container.encode(total, forKey: .total_h)
        case .count(let value):
            try container.encode("count", forKey: .type)
            try container.encode(value, forKey: .value)
        case .meals(let entries):
            try container.encode("meals", forKey: .type)
            try container.encode(entries, forKey: .entries)
        case .heatmap(let entries):
            try container.encode("heatmap", forKey: .type)
            try container.encode(entries, forKey: .entries)
        case .scalarGroup(let items):
            try container.encode("scalar_group", forKey: .type)
            try container.encode(items, forKey: .items)
        }
    }
}

// MARK: - Layout summary (from GET /api/v1/layouts list)

struct LayoutSummary: Codable, Identifiable {
    let id: String
    let version: Int
    let title: String
    let cadence: String
    let active_from: String?
    let active_until: String?
    let updated_at: String
}
