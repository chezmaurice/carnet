import SwiftUI

struct ScalarGroupWidget: View {
    let widget: WidgetSpec
    let value: ResolvedMetric

    private var label: String { widget.params?["label"]?.stringValue ?? "" }
    private var unit: String { widget.params?["unit"]?.stringValue ?? "" }
    private var showDelta: Bool { widget.params?["show_delta"]?.boolValue ?? false }

    var body: some View {
        WidgetCard(title: label) {
            switch value {
            case .scalar(let v, _):
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(v != nil ? "\(v!, specifier: formatSpecifier(v!))" : "—")
                            .font(CarnetTheme.metricLarge)
                            .foregroundStyle(v != nil ? CarnetTheme.ink : CarnetTheme.inkHint)
                            .tracking(-0.3)
                        if v != nil {
                            Text(unit)
                                .font(CarnetTheme.unitLabel)
                                .foregroundStyle(CarnetTheme.inkMute)
                        }
                    }
                    if showDelta {
                        let delta = Double.random(in: -3...3) // stub delta
                        deltaLabel(delta)
                    }
                }
            case .scalarGroup(let items):
                VStack(alignment: .leading, spacing: CarnetTheme.itemSpacing) {
                    ForEach(items, id: \.label) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.label)
                                .font(CarnetTheme.caption)
                                .foregroundStyle(CarnetTheme.inkSoft)
                            Spacer()
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(item.value, specifier: "%.1f")")
                                    .font(CarnetTheme.monoCaption)
                                    .foregroundStyle(CarnetTheme.ink)
                                Text(item.unit)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(CarnetTheme.inkMute)
                            }
                        }
                    }
                }
            case .count(let c):
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(c)")
                        .font(CarnetTheme.metricLarge)
                        .foregroundStyle(CarnetTheme.ink)
                        .tracking(-0.3)
                    Text(unit)
                        .font(CarnetTheme.unitLabel)
                        .foregroundStyle(CarnetTheme.inkMute)
                }
            default:
                Text("—").foregroundStyle(CarnetTheme.inkHint)
            }
        }
    }

    private func formatSpecifier(_ v: Double) -> String {
        v == v.rounded() ? "%.0f" : "%.1f"
    }

    @ViewBuilder
    private func deltaLabel(_ delta: Double) -> some View {
        let direction = widget.params?["delta_direction"]?.stringValue ?? "none"
        let color = CarnetTheme.deltaColor(delta: delta, direction: direction)
        let arrow = delta > 0 ? "arrow.up.right" : "arrow.down.right"

        HStack(spacing: 4) {
            Image(systemName: arrow)
                .font(.system(size: 7))
            Text("\(abs(delta), specifier: "%.1f")")
                .font(CarnetTheme.monoCaption)
        }
        .foregroundStyle(color)
    }
}
