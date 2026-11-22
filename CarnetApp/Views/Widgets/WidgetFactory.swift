import SwiftUI

enum WidgetFactory {
    @ViewBuilder
    static func build(widget: WidgetSpec, value: ResolvedMetric?, metricService: MetricService) -> some View {
        switch widget.type {
        case "sparkline":
            if let value { SparklineWidget(widget: widget, value: value) }
        case "progress_bar":
            if let value { ProgressBarWidget(widget: widget, value: value) }
        case "sleep_ring":
            if let value { SleepRingWidget(widget: widget, value: value) }
        case "scalar_value", "scalar_group":
            if let value { ScalarGroupWidget(widget: widget, value: value) }
        case "progress_donut":
            if let value { ProgressDonutWidget(widget: widget, value: value) }
        case "boolean_chip":
            if let value { BooleanChipWidget(widget: widget, value: value) }
        case "adherence_heatmap":
            AdherenceHeatmapWidget(widget: widget, metricService: metricService)
        case "meal_list":
            if let value { MealListWidget(widget: widget, value: value) }
        default:
            PlaceholderWidget(typeName: widget.type)
        }
    }
}
