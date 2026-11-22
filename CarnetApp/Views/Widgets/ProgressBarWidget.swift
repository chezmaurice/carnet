import SwiftUI

struct ProgressBarWidget: View {
    let widget: WidgetSpec
    let value: ResolvedMetric

    private var label: String { widget.params?["label"]?.stringValue ?? "" }
    private var unit: String { widget.params?["unit"]?.stringValue ?? "" }
    private var startValue: Double { widget.params?["start_value"]?.doubleValue ?? 0 }
    private var targetValue: Double { widget.params?["target_value"]?.doubleValue ?? 100 }
    private var lowerIsBetter: Bool { widget.params?["direction"]?.stringValue == "lower_is_better" }

    var body: some View {
        WidgetCard(title: label) {
            let current: Double? = {
                switch value {
                case .scalar(let v, _): return v
                case .count(let c): return Double(c)
                default: return nil
                }
            }()

            if let current {
                let progressPct: Double = {
                    let p: Double
                    if lowerIsBetter {
                        p = (startValue - current) / (startValue - targetValue)
                    } else {
                        p = (current - startValue) / (targetValue - startValue)
                    }
                    return max(0, min(1, p))
                }()

                VStack(alignment: .leading, spacing: 0) {
                    // Top row: current value + percentage
                    HStack(alignment: .firstTextBaseline) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(current, specifier: "%.1f")")
                                .font(CarnetTheme.metricMedium)
                                .foregroundStyle(CarnetTheme.ink)
                                .tracking(-0.3)
                            Text(unit)
                                .font(.system(size: 11))
                                .foregroundStyle(CarnetTheme.inkMute)
                        }
                        Spacer()
                        Text("\(Int(progressPct * 100))%")
                            .font(CarnetTheme.monoCaption)
                            .foregroundStyle(CarnetTheme.inkMute)
                    }
                    .padding(.bottom, 14)

                    // Rail
                    GeometryReader { geo in
                        let w = geo.size.width
                        let lo = min(startValue, current, targetValue)
                        let hi = max(startValue, current, targetValue)
                        let range = hi - lo > 0 ? hi - lo : 1.0
                        let padPct = 0.08
                        let totalSpan = range * (1 + padPct * 2)
                        let baseLo = lo - range * padPct

                        let px = { (v: Double) -> CGFloat in
                            CGFloat((v - baseLo) / totalSpan) * w
                        }

                        let startX = px(startValue)
                        let currentX = px(current)
                        let targetX = px(targetValue)

                        ZStack(alignment: .leading) {
                            // Baseline rail
                            Rectangle()
                                .fill(CarnetTheme.ruleHard)
                                .frame(height: 1)
                                .position(x: w / 2, y: 4)

                            // Filled segment: start → current
                            let segLeft = min(startX, currentX)
                            let segWidth = abs(currentX - startX)
                            Rectangle()
                                .fill(CarnetTheme.ink)
                                .frame(width: segWidth, height: 3)
                                .position(x: segLeft + segWidth / 2, y: 4)

                            // Start tick
                            Rectangle()
                                .fill(CarnetTheme.inkMute)
                                .frame(width: 1, height: 9)
                                .position(x: startX, y: 4)

                            // Target tick
                            Rectangle()
                                .fill(CarnetTheme.inkMute)
                                .frame(width: 1, height: 9)
                                .position(x: targetX, y: 4)

                            // Current marker (circle)
                            Circle()
                                .fill(CarnetTheme.surface)
                                .overlay(Circle().stroke(CarnetTheme.ink, lineWidth: 1.5))
                                .frame(width: 10, height: 10)
                                .position(x: currentX, y: 4)
                        }
                    }
                    .frame(height: 8)
                    .padding(.bottom, 10)

                    // Labels row
                    GeometryReader { geo in
                        let w = geo.size.width
                        let lo = min(startValue, current, targetValue)
                        let hi = max(startValue, current, targetValue)
                        let range = hi - lo > 0 ? hi - lo : 1.0
                        let padPct = 0.08
                        let totalSpan = range * (1 + padPct * 2)
                        let baseLo = lo - range * padPct

                        let px = { (v: Double) -> CGFloat in
                            CGFloat((v - baseLo) / totalSpan) * w
                        }

                        // Start label
                        VStack(spacing: 1) {
                            Text("START")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(CarnetTheme.inkMute)
                                .tracking(1.2)
                            HStack(spacing: 2) {
                                Text("\(startValue, specifier: "%.1f")")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(CarnetTheme.inkSoft)
                                Text(unit)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(CarnetTheme.inkHint)
                            }
                        }
                        .position(x: px(startValue), y: 12)

                        // Target label
                        VStack(spacing: 1) {
                            Text("TARGET")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(CarnetTheme.inkMute)
                                .tracking(1.2)
                            HStack(spacing: 2) {
                                Text("\(targetValue, specifier: "%.1f")")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(CarnetTheme.inkSoft)
                                Text(unit)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(CarnetTheme.inkHint)
                            }
                        }
                        .position(x: px(targetValue), y: 12)
                    }
                    .frame(height: 24)
                }
            } else {
                Text("—").foregroundStyle(CarnetTheme.inkHint)
            }
        }
    }
}
