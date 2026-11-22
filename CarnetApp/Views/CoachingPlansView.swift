import SwiftUI

struct CoachingPlansView: View {
    @State private var plans: [CarnetAPI.CoachingPlan] = []
    @State private var isLoading = true
    @State private var showArchived = false
    @State private var selectedPlan: CarnetAPI.CoachingPlan?
    @State private var showNewPlan = false
    @State private var error: String?

    private var activePlans: [CarnetAPI.CoachingPlan] {
        plans.filter { $0.isActive }
    }

    private var inactivePlans: [CarnetAPI.CoachingPlan] {
        plans.filter { !$0.isActive }
    }

    private var groupedActive: [(String, [CarnetAPI.CoachingPlan])] {
        let dict = Dictionary(grouping: activePlans) { $0.category ?? "Other" }
        return dict.sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && plans.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if plans.isEmpty {
                    ContentUnavailableView(
                        "No Coaching Plans",
                        systemImage: "target",
                        description: Text("Create a plan to start tracking your habits.")
                    )
                } else {
                    planList
                }
            }
            .navigationTitle("Coaching")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNewPlan = true } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle("Show Archived", isOn: $showArchived)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(item: $selectedPlan) { plan in
                PlanEditorView(plan: plan) { await loadPlans() }
            }
            .sheet(isPresented: $showNewPlan) {
                PlanEditorView(plan: nil) { await loadPlans() }
            }
            .task { await loadPlans() }
            .refreshable { await loadPlans() }
            .onChange(of: showArchived) { Task { await loadPlans() } }
        }
    }

    private var planList: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            // Active plans, grouped by category
            if !activePlans.isEmpty {
                ForEach(groupedActive, id: \.0) { category, plans in
                    Section {
                        ForEach(plans) { plan in
                            PlanRow(plan: plan)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedPlan = plan }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: iconForCategory(category))
                                .font(.caption)
                            Text(category.localizedCapitalized)
                        }
                    }
                }
            }

            // Inactive / archived plans
            if showArchived && !inactivePlans.isEmpty {
                Section("Archived") {
                    ForEach(inactivePlans) { plan in
                        PlanRow(plan: plan, dimmed: true)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedPlan = plan }
                    }
                    .onDelete(perform: deleteInactive)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Actions

    private func loadPlans() async {
        isLoading = true
        do {
            plans = try await CarnetAPI.fetchCoachingPlans(includeArchived: showArchived)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func deleteInactive(at offsets: IndexSet) {
        let toDelete = offsets.map { inactivePlans[$0] }
        Task {
            for plan in toDelete {
                try? await CarnetAPI.deleteCoachingPlan(id: plan.id)
            }
            await loadPlans()
        }
    }

    private func iconForCategory(_ category: String) -> String {
        switch category.lowercased() {
        case "health", "santé": return "heart.fill"
        case "work", "career", "carrière": return "briefcase.fill"
        case "fitness": return "figure.run"
        default: return "target"
        }
    }
}

// MARK: - Plan Row

struct PlanRow: View {
    let plan: CarnetAPI.CoachingPlan
    var dimmed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title row
            HStack(spacing: 8) {
                planIcon
                    .font(.title3)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.title)
                        .font(.headline)
                        .lineLimit(2)

                    if let desc = plan.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                // Status badge
                statusBadge
            }

            // Metrics summary
            metricsStrip
        }
        .padding(.vertical, 4)
        .opacity(dimmed ? 0.5 : 1)
    }

    @ViewBuilder
    private var planIcon: some View {
        if let icon = plan.icon {
            // Map common Lucide icon names to SF Symbols
            Image(systemName: sfSymbol(for: icon))
                .foregroundStyle(Color.accentColor)
        } else {
            Image(systemName: "target")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if plan.archived {
            Text("Archived")
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary)
                .clipShape(Capsule())
        } else if let until = plan.active_until {
            Text("until \(until)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var metricsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(plan.metrics) { metric in
                    MetricChip(metric: metric)
                }
            }
        }
    }

    private func sfSymbol(for lucideIcon: String) -> String {
        let map: [String: String] = [
            "dumbbell": "dumbbell.fill",
            "heart": "heart.fill",
            "heart-pulse": "heart.fill",
            "wind": "wind",
            "utensils": "fork.knife",
            "brain": "brain.head.profile",
            "book": "book.fill",
            "pen": "pencil",
            "feather": "pencil.line",
            "eye": "eye.fill",
            "ear": "ear.fill",
            "users": "person.2.fill",
            "target": "target",
            "activity": "waveform.path.ecg",
            "flame": "flame.fill",
            "moon": "moon.fill",
            "sun": "sun.max.fill",
            "leaf": "leaf.fill",
            "zap": "bolt.fill",
            "shield": "shield.fill",
            "thermometer": "thermometer.medium",
        ]
        return map[lucideIcon] ?? "target"
    }
}

// MARK: - Metric Chip

struct MetricChip: View {
    let metric: CarnetAPI.CoachingMetric

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconForCategory(metric.signal_category))
                .font(.caption2)
            Text(metric.pillar)
                .font(.caption2)
                .lineLimit(1)
            Text(metric.targetDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(colorForCategory(metric.signal_category).opacity(0.12))
        .clipShape(Capsule())
    }

    private func iconForCategory(_ cat: String) -> String {
        switch cat {
        case "sports": return "figure.run"
        case "breathing": return "wind"
        case "meditation": return "brain.head.profile"
        case "eating": return "fork.knife"
        case "supplements": return "pill.fill"
        case "alcohol": return "wineglass.fill"
        case "measurement": return "ruler.fill"
        case "network": return "person.2.fill"
        case "reading": return "book.fill"
        case "writing": return "pencil.line"
        case "watching": return "tv.fill"
        case "listening": return "headphones"
        default: return "circle.fill"
        }
    }

    private func colorForCategory(_ cat: String) -> Color {
        switch cat {
        case "sports": return .orange
        case "breathing": return .cyan
        case "meditation": return .purple
        case "eating": return .green
        case "supplements": return .mint
        case "alcohol": return .red
        case "measurement": return .blue
        case "network": return .indigo
        case "reading", "writing": return .brown
        default: return .gray
        }
    }
}
