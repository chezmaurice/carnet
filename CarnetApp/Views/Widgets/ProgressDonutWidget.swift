import SwiftUI

struct ProgressDonutWidget: View {
    let widget: WidgetSpec
    let value: ResolvedMetric

    private var label: String { widget.params?["label"]?.stringValue ?? "" }
    private var unit: String { widget.params?["unit"]?.stringValue ?? "" }
    private var goal: Double { widget.params?["goal"]?.doubleValue ?? 1 }
    private var mode: String { widget.params?["mode"]?.stringValue ?? "continuous" }
    private var periodLabel: String { widget.params?["period_label"]?.stringValue ?? "" }

    var body: some View {
        WidgetCard(title: label) {
            let current: Double = {
                switch value {
                case .scalar(let v, _): return v ?? 0
                case .count(let c): return Double(c)
                default: return 0
                }
            }()
            let progress = goal > 0 ? current / goal : 0
            let met = current >= goal
            let exceeded = current > goal
            let arcColor = exceeded ? CarnetTheme.good : CarnetTheme.ink

            HStack(spacing: CarnetTheme.donutGap) {
                ZStack {
                    Circle()
                        .stroke(CarnetTheme.rule, lineWidth: CarnetTheme.progressStrokeWidth)
                    Circle()
                        .trim(from: 0, to: min(progress, 1.0))
                        .stroke(arcColor, style: StrokeStyle(lineWidth: CarnetTheme.progressStrokeWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))

                    if mode == "discrete" {
                        // Session donut: "3/5" center
                        HStack(spacing: 1) {
                            Text("\(Int(current))")
                                .font(CarnetTheme.donutMono)
                                .foregroundStyle(CarnetTheme.ink)
                            Text("/")
                                .font(CarnetTheme.donutMono)
                                .foregroundStyle(CarnetTheme.inkHint)
                            Text("\(Int(goal))")
                                .font(CarnetTheme.donutMono)
                                .foregroundStyle(CarnetTheme.inkMute)
                        }
                    } else {
                        // Duration donut: value + unit stacked
                        VStack(spacing: 2) {
                            Text("\(Int(current))")
                                .font(CarnetTheme.metricSmall)
                                .foregroundStyle(CarnetTheme.ink)
                            Text(unit.uppercased())
                                .font(CarnetTheme.donutUnit)
                                .foregroundStyle(CarnetTheme.inkMute)
                                .tracking(0.6)
                        }
                    }
                }
                .frame(width: CarnetTheme.donutSize, height: CarnetTheme.donutSize)

                VStack(alignment: .leading, spacing: 3) {
                    if !periodLabel.isEmpty {
                        Text(periodLabel.uppercased())
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(CarnetTheme.inkMute)
                            .tracking(1.2)
                    }
                    Text(statusText(current: current, goal: goal, met: met, exceeded: exceeded))
                        .font(CarnetTheme.caption)
                        .foregroundStyle(CarnetTheme.inkSoft)
                    if mode == "continuous" {
                        Text("\(Int(current)) / \(Int(goal)) \(unit)")
                            .font(CarnetTheme.monoCaption)
                            .foregroundStyle(CarnetTheme.inkMute)
                    }
                }
            }
        }
    }

    private func statusText(current: Double, goal: Double, met: Bool, exceeded: Bool) -> String {
        if met {
            return exceeded ? "+\(Int(current - goal)) over goal" : "goal met"
        }
        return "\(Int(goal - current)) to go"
    }
}
