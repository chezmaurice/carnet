import SwiftUI

struct SleepRingWidget: View {
    let widget: WidgetSpec
    let value: ResolvedMetric

    private var label: String { widget.params?["label"]?.stringValue ?? "Sleep stages" }

    var body: some View {
        WidgetCard(title: label) {
            if case .sleepStages(let core, let rem, let deep, let awake, let totalInBed) = value {
                let total = core + rem + deep + awake // for arc proportions
                let asleep = core + rem + deep // actual sleep time (excl. awake)
                let displayTotal = asleep > 0 ? asleep : totalInBed // center number
                // Display order matches design: Core, REM, Deep, Awake
                let segments: [(String, Double, Color)] = [
                    ("Core", core, CarnetTheme.sleepCore),
                    ("REM", rem, CarnetTheme.sleepREM),
                    ("Deep", deep, CarnetTheme.sleepDeep),
                    ("Awake", awake, CarnetTheme.sleepAwake),
                ]

                HStack(spacing: CarnetTheme.donutGap) {
                    // Donut ring — left side
                    ZStack {
                        SleepArc(segments: segments, total: total)
                            .frame(width: CarnetTheme.sleepRingSize, height: CarnetTheme.sleepRingSize)
                        // Center: total time in bed "6h 55m"
                        let totalMinutes = Int(displayTotal * 60)
                        let hours = totalMinutes / 60
                        let minutes = totalMinutes % 60
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(hours)")
                                .font(CarnetTheme.headline)
                                .foregroundStyle(CarnetTheme.ink)
                            Text("h")
                                .font(CarnetTheme.donutUnit)
                                .foregroundStyle(CarnetTheme.inkMute)
                            Text(" \(String(format: "%02d", minutes))")
                                .font(CarnetTheme.headline)
                                .foregroundStyle(CarnetTheme.ink)
                            Text("m")
                                .font(CarnetTheme.donutUnit)
                                .foregroundStyle(CarnetTheme.inkMute)
                        }
                    }

                    // Legend — right side, 4 rows
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(segments, id: \.0) { seg in
                            HStack(spacing: CarnetTheme.itemSpacing) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(seg.2)
                                    .frame(width: CarnetTheme.legendDotSize, height: CarnetTheme.legendDotSize)
                                Text(seg.0)
                                    .font(CarnetTheme.caption)
                                    .foregroundStyle(CarnetTheme.inkSoft)
                                Spacer()
                                Text(formatDuration(seg.1))
                                    .font(CarnetTheme.monoCaptionSmall)
                                    .foregroundStyle(CarnetTheme.ink)
                            }
                        }
                    }
                }
            } else {
                Text("no data")
                    .font(.system(size: 14, design: .serif))
                    .italic()
                    .foregroundStyle(CarnetTheme.inkHint)
            }
        }
    }

    private func formatDuration(_ hours: Double) -> String {
        let totalMin = Int(hours * 60)
        let h = totalMin / 60
        let m = totalMin % 60
        if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
        return "\(m)m"
    }
}

// MARK: - Multi-arc donut renderer

private struct SleepArc: View {
    let segments: [(String, Double, Color)]
    let total: Double

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - CarnetTheme.sleepRingStrokeWidth / 2
            var startAngle = Angle.degrees(-90)

            for (_, value, color) in segments {
                guard total > 0 else { continue }
                let sweep = Angle.degrees(360 * (value / total))
                let gap = Angle.degrees(1.5) // tiny gap between arcs
                let endAngle = startAngle + sweep - gap

                if sweep.degrees > 2 {
                    var path = Path()
                    path.addArc(center: center, radius: radius,
                                startAngle: startAngle, endAngle: endAngle,
                                clockwise: false)

                    context.stroke(path, with: .color(color),
                                  style: StrokeStyle(lineWidth: CarnetTheme.sleepRingStrokeWidth, lineCap: .butt))
                }

                startAngle = startAngle + sweep
            }
        }
    }
}
