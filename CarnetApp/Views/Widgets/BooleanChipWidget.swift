import SwiftUI

struct BooleanChipWidget: View {
    let widget: WidgetSpec
    let value: ResolvedMetric

    private var label: String { widget.params?["label"]?.stringValue ?? "" }
    private var threshold: Int { widget.params?["true_threshold"]?.intValue ?? 1 }

    var body: some View {
        let done: Bool = {
            switch value {
            case .count(let c): return c >= threshold
            case .scalar(let v, _): return Int(v ?? 0) >= threshold
            default: return false
            }
        }()

        HStack(spacing: CarnetTheme.itemSpacing) {
            // Square checkbox
            ZStack {
                RoundedRectangle(cornerRadius: CarnetTheme.checkboxCornerRadius)
                    .stroke(done ? Color.clear : CarnetTheme.inkMute,
                            lineWidth: CarnetTheme.checkboxBorderWidth)
                    .frame(width: CarnetTheme.checkboxSize, height: CarnetTheme.checkboxSize)

                if done {
                    RoundedRectangle(cornerRadius: CarnetTheme.checkboxCornerRadius)
                        .fill(CarnetTheme.ink)
                        .frame(width: CarnetTheme.checkboxSize, height: CarnetTheme.checkboxSize)
                    // Checkmark
                    Path { path in
                        path.move(to: CGPoint(x: 3.5, y: 7))
                        path.addLine(to: CGPoint(x: 6, y: 10))
                        path.addLine(to: CGPoint(x: 10.5, y: 4.5))
                    }
                    .stroke(CarnetTheme.surface, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: CarnetTheme.checkboxSize, height: CarnetTheme.checkboxSize)
                } else {
                    // X mark
                    Path { path in
                        path.move(to: CGPoint(x: 4.5, y: 4.5))
                        path.addLine(to: CGPoint(x: 9.5, y: 9.5))
                        path.move(to: CGPoint(x: 9.5, y: 4.5))
                        path.addLine(to: CGPoint(x: 4.5, y: 9.5))
                    }
                    .stroke(CarnetTheme.inkHint, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .frame(width: CarnetTheme.checkboxSize, height: CarnetTheme.checkboxSize)
                }
            }

            Text(label)
                .font(CarnetTheme.captionBold)
                .foregroundStyle(done ? CarnetTheme.ink : CarnetTheme.inkMute)
        }
    }
}
