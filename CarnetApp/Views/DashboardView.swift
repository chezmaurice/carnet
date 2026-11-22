import SwiftUI

struct DashboardView: View {
    let layoutID: String
    let layoutService: LayoutService
    let metricService: MetricService
    var onMenu: (() -> Void)? = nil

    @State private var spec: LayoutSpec?
    @State private var error: String?
    @State private var loading = true
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var activeAction: LogKind?

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    var body: some View {
        ZStack {
            Group {
                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: CarnetTheme.rowSpacing) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(CarnetTheme.inkMute)
                        Text(error)
                            .font(CarnetTheme.subheadline)
                            .foregroundStyle(CarnetTheme.inkSoft)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let spec {
                    ZStack {
                        ScrollView {
                            VStack(spacing: 0) {
                                // Header — date eyebrow + hairline
                                DashboardHeader(dateLabel: dateEyebrow, onMenu: onMenu)

                                // Widget sections
                                VStack(spacing: 0) {
                                    ForEach(spec.spec.rows) { row in
                                        DashboardSection(row: row, metricService: metricService)
                                    }
                                }
                                .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                                .padding(.bottom, CarnetTheme.pageVerticalPadding + 80)
                            }
                        }

                        // Invisible edge tap bands for date navigation. Inset from
                        // the top so they don't sit over the header controls (the
                        // ☰ menu lives in the top-left, where the left band would be).
                        HStack(spacing: 0) {
                            Color.clear
                                .frame(width: 50)
                                .contentShape(Rectangle())
                                .onTapGesture { navigateDay(offset: -1) }

                            Spacer()

                            Color.clear
                                .frame(width: 50)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if !isToday { navigateDay(offset: 1) }
                                }
                        }
                        .padding(.top, 64)
                        .allowsHitTesting(true)
                    }
                }
            }
            .background(CarnetTheme.bg)
            .task {
                await loadDashboard()
            }
            .refreshable {
                await loadDashboard(refresh: true)
            }
            .opacity(activeAction == nil ? 1 : 0)
            .allowsHitTesting(activeAction == nil)

            // FAB — fixed bottom-right, outside scroll content
            if activeAction == nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        LogFabView { kind in
                            withAnimation(.easeOut(duration: 0.2)) {
                                activeAction = kind
                            }
                        }
                        .padding(.trailing, 24)
                        .padding(.bottom, 24)
                    }
                }
            }

            if let action = activeAction {
                LogActionView(kind: action) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        activeAction = nil
                    }
                }
            }
        }
    }

    // MARK: - Header label

    private var dateEyebrow: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE · d MMM yyyy"
        return formatter.string(from: selectedDate).uppercased()
    }

    private func navigateDay(offset: Int) {
        guard let newDate = Calendar.current.date(byAdding: .day, value: offset, to: selectedDate) else { return }
        if newDate > Calendar.current.startOfDay(for: Date()) { return }
        selectedDate = newDate
        Task { await loadDashboard() }
    }

    // MARK: - Data loading

    private func loadDashboard(refresh: Bool = false) async {
        let isInitialLoad = spec == nil
        if isInitialLoad { loading = true }
        error = nil
        do {
            if isInitialLoad {
                _ = try await layoutService.fetchList()
                spec = try await layoutService.fetchSpec(id: layoutID)
            }
            try await metricService.fetchDashboardData(layoutId: layoutID, date: selectedDate, refresh: refresh)
        } catch {
            self.error = error.localizedDescription
        }
        if isInitialLoad { loading = false }
    }
}

// MARK: - Dashboard header — date eyebrow + hairline

private struct DashboardHeader: View {
    let dateLabel: String
    var onMenu: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let onMenu {
                    Button(action: onMenu) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 18)).foregroundStyle(CarnetTheme.inkSoft)
                    }.buttonStyle(.plain)
                }
                Text(dateLabel)
                    .font(CarnetTheme.headerEyebrow)
                    .foregroundStyle(CarnetTheme.inkMute)
                    .textCase(.uppercase)
                    .tracking(CarnetTheme.sectionLabelTracking)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
            .padding(.top, 14)
            .padding(.bottom, 14)

            Rectangle()
                .fill(CarnetTheme.rule)
                .frame(height: 0.5)
        }
    }
}

// MARK: - Dashboard section — section label + 2-col grid of widgets

private struct DashboardSection: View {
    let row: LayoutRow
    let metricService: MetricService

    /// Widget types that should span full width
    private static let fullWidthTypes: Set<String> = [
        "adherence_heatmap", "meal_list", "sleep_ring", "narrative"
    ]

    private var halfWidgets: [WidgetSpec] {
        row.widgets.filter { !Self.fullWidthTypes.contains($0.type) && $0.effectiveSpan < 2 }
    }

    private var fullWidgets: [WidgetSpec] {
        row.widgets.filter { Self.fullWidthTypes.contains($0.type) || $0.effectiveSpan >= 2 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CarnetTheme.rowSpacing) {
            // Section eyebrow
            if let section = row.section {
                Text(section.uppercased())
                    .font(CarnetTheme.sectionLabel)
                    .foregroundStyle(CarnetTheme.inkMute)
                    .textCase(.uppercase)
                    .tracking(CarnetTheme.sectionLabelTracking)
                    .padding(.top, 20)
                    .padding(.bottom, 2)
            }

            // Half-width widgets in a 2-col grid
            let halves = halfWidgets
            if !halves.isEmpty {
                WidgetPairGrid(widgets: halves, metricService: metricService)
            }

            // Full-width widgets stacked
            ForEach(fullWidgets) { widget in
                WidgetContainer(widget: widget, metricService: metricService)
            }
        }
    }
}

// MARK: - 2-column pairing for half-width widgets

private struct WidgetPairGrid: View {
    let widgets: [WidgetSpec]
    let metricService: MetricService

    var body: some View {
        // Pair widgets into rows of 2
        let pairs = stride(from: 0, to: widgets.count, by: 2).map { i in
            let end = min(i + 2, widgets.count)
            return Array(widgets[i..<end])
        }

        VStack(spacing: CarnetTheme.rowSpacing) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: CarnetTheme.widgetSpacing) {
                    ForEach(pair) { widget in
                        WidgetContainer(widget: widget, metricService: metricService)
                            .frame(maxWidth: .infinity)
                    }
                    // If odd number, add spacer to keep half-width
                    if pair.count == 1 {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

// MARK: - Per-widget container — reads from MetricService's resolved metrics

private struct WidgetContainer: View {
    let widget: WidgetSpec
    let metricService: MetricService

    var body: some View {
        if metricService.isLoading {
            WidgetCard(title: widgetLabel) {
                WidgetSkeleton()
            }
        } else {
            let resolved = resolvedMetric
            if resolved != nil || widget.type == "adherence_heatmap" {
                WidgetFactory.build(widget: widget, value: resolved, metricService: metricService)
            } else {
                WidgetCard(title: widgetLabel) {
                    Text("No data")
                        .font(CarnetTheme.caption)
                        .foregroundStyle(CarnetTheme.inkHint)
                }
            }
        }
    }

    private var widgetLabel: String? {
        widget.params?["label"]?.stringValue
    }

    private var resolvedMetric: ResolvedMetric? {
        switch widget.data {
        case .single(let binding):
            return metricService.metric(for: binding)
        case .multi:
            return nil
        }
    }
}
