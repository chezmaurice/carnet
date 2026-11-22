import SwiftUI

struct AdherenceHeatmapWidget: View {
    let widget: WidgetSpec
    let metricService: MetricService

    private var weeks: Int { widget.params?["weeks"]?.intValue ?? 4 }

    private var bindings: [WidgetDataBinding] {
        if case .multi(let b) = widget.data { return b }
        return []
    }

    private var labels: [String] {
        bindings.compactMap(\.label)
    }

    private static let dayLabels = ["S", "M", "T", "W", "T", "F", "S"]

    /// Fixed label column width — enough for typical habit names
    private let labelWidth: CGFloat = 80

    var body: some View {
        WidgetCard(title: "Adherence") {
            let rows = metricService.heatmapRows(for: bindings)
            if !rows.isEmpty {
                let totalDays = weeks * 7
                VStack(alignment: .leading, spacing: CarnetTheme.heatmapCellGap) {
                    // Day headers
                    GeometryReader { geo in
                        let cellSize = cellSize(totalWidth: geo.size.width, days: totalDays)
                        HStack(spacing: CarnetTheme.heatmapCellGap) {
                            Color.clear
                                .frame(width: labelWidth)
                            ForEach(0..<min(totalDays, 7), id: \.self) { i in
                                Text(Self.dayLabels[i])
                                    .font(.system(size: max(cellSize * 0.8, 6), design: .monospaced))
                                    .foregroundStyle(CarnetTheme.inkMute)
                                    .frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                    .frame(height: cellHeight(totalDays: totalDays))

                    // Habit rows
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                        GeometryReader { geo in
                            let cellSize = cellSize(totalWidth: geo.size.width, days: totalDays)
                            HStack(spacing: CarnetTheme.heatmapCellGap) {
                                Text(rowIdx < labels.count ? labels[rowIdx] : "—")
                                    .font(.system(size: 11))
                                    .foregroundStyle(CarnetTheme.inkSoft)
                                    .frame(width: labelWidth, alignment: .leading)
                                    .lineLimit(1)

                                let days = Array(row.suffix(totalDays))
                                ForEach(Array(days.enumerated()), id: \.offset) { _, count in
                                    RoundedRectangle(cornerRadius: CarnetTheme.heatmapCellRadius)
                                        .fill(CarnetTheme.heatmapColor(count))
                                        .frame(width: cellSize, height: cellSize)
                                }
                            }
                        }
                        .frame(height: cellHeight(totalDays: totalDays))
                    }
                }
            } else {
                Text("—").foregroundStyle(CarnetTheme.inkHint)
            }
        }
    }

    /// Compute cell size to fill available width after the label column
    private func cellSize(totalWidth: CGFloat, days: Int) -> CGFloat {
        let availableWidth = totalWidth - labelWidth - CarnetTheme.heatmapCellGap
        let gaps = CGFloat(days - 1) * CarnetTheme.heatmapCellGap
        return max((availableWidth - gaps) / CGFloat(days), 4)
    }

    private func cellHeight(totalDays: Int) -> CGFloat {
        // Estimate — will be computed per-row by GeometryReader
        // Use a reasonable default based on typical screen width (~358 usable)
        let estimated = cellSize(totalWidth: 330, days: totalDays)
        return max(estimated, 8)
    }
}
