import SwiftUI

struct SparklineWidget: View {
    let widget: WidgetSpec
    let value: ResolvedMetric

    private var label: String { widget.params?["label"]?.stringValue ?? "" }
    private var unit: String { widget.params?["unit"]?.stringValue ?? "" }
    private var showCurrent: Bool { widget.params?["show_current"]?.boolValue ?? true }

    var body: some View {
        WidgetCard(title: label) {
            switch value {
            case .series(let points):
                HStack(alignment: .bottom, spacing: 12) {
                    if showCurrent, let last = points.last {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(last.value, specifier: "%.0f")")
                                    .font(CarnetTheme.metricMedium)
                                    .foregroundStyle(CarnetTheme.ink)
                                    .tracking(-0.3)
                                Text(unit)
                                    .font(.system(size: 11))
                                    .foregroundStyle(CarnetTheme.inkMute)
                            }
                        }
                        .frame(minWidth: 0, alignment: .leading)
                    }
                    SparklinePath(values: points.map(\.value))
                        .stroke(CarnetTheme.ink, style: StrokeStyle(
                            lineWidth: CarnetTheme.sparklineStrokeWidth,
                            lineCap: .round, lineJoin: .round))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .scalar(let v, _):
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(v != nil ? "\(v!, specifier: "%.0f")" : "—")
                        .font(CarnetTheme.metricLarge)
                        .foregroundStyle(v != nil ? CarnetTheme.ink : CarnetTheme.inkHint)
                        .tracking(-0.3)
                    Text(unit)
                        .font(.system(size: 11))
                        .foregroundStyle(CarnetTheme.inkMute)
                }
            default:
                Text("—").foregroundStyle(CarnetTheme.inkHint)
            }
        }
    }
}

private struct SparklinePath: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        guard values.count >= 2 else { return Path() }
        let minV = values.min()!
        let maxV = values.max()!
        let range = maxV - minV > 0 ? maxV - minV : 1
        let padY: CGFloat = 3

        var path = Path()
        for (i, val) in values.enumerated() {
            let x = rect.width * CGFloat(i) / CGFloat(values.count - 1)
            let y = padY + (rect.height - padY * 2) * (1 - CGFloat((val - minV) / range))
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}
