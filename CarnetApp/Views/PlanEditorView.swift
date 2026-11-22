import SwiftUI

struct PlanEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let initialPlan: CarnetAPI.CoachingPlan?
    let onSave: () async -> Void

    @State private var title: String = ""
    @State private var description: String = ""
    @State private var icon: String = ""
    @State private var category: String = ""
    @State private var activeFrom: String = ""
    @State private var activeUntil: String = ""
    @State private var archived: Bool = false
    @State private var metrics: [CarnetAPI.CoachingMetric] = []

    @State private var isSaving = false
    @State private var showDeleteConfirm = false
    @State private var error: String?
    @State private var editingMetricIndex: Int?
    @State private var showNewMetric = false

    private var isNew: Bool { initialPlan == nil }

    init(plan: CarnetAPI.CoachingPlan?, onSave: @escaping () async -> Void) {
        self.initialPlan = plan
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                // Identity
                Section {
                    TextField("Title", text: $title)
                        .font(.headline)

                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.subheadline)

                    HStack {
                        Label("Icon", systemImage: "paintbrush")
                        Spacer()
                        TextField("e.g. dumbbell", text: $icon)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 150)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Category", systemImage: "folder")
                        Spacer()
                        TextField("e.g. health", text: $category)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 150)
                            .foregroundStyle(.secondary)
                    }
                }

                // Schedule
                Section("Schedule") {
                    HStack {
                        Label("Active from", systemImage: "calendar")
                        Spacer()
                        TextField("YYYY-MM-DD", text: $activeFrom)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                            .foregroundStyle(activeFrom.isEmpty ? .tertiary : .primary)
                            .keyboardType(.numbersAndPunctuation)
                    }

                    HStack {
                        Label("Active until", systemImage: "calendar.badge.clock")
                        Spacer()
                        TextField("YYYY-MM-DD", text: $activeUntil)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                            .foregroundStyle(activeUntil.isEmpty ? .tertiary : .primary)
                            .keyboardType(.numbersAndPunctuation)
                    }

                    if !isNew {
                        Toggle(isOn: $archived) {
                            Label("Archived", systemImage: "archivebox")
                        }
                    }
                }

                // Metrics
                Section {
                    if metrics.isEmpty {
                        ContentUnavailableView {
                            Label("No Metrics", systemImage: "chart.bar")
                        } description: {
                            Text("Add metrics to define what this plan tracks.")
                        }
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                            MetricRow(metric: metric)
                                .contentShape(Rectangle())
                                .onTapGesture { editingMetricIndex = index }
                        }
                        .onDelete(perform: deleteMetrics)
                        .onMove(perform: moveMetrics)
                    }
                } header: {
                    HStack {
                        Text("Metrics (\(metrics.count))")
                        Spacer()
                        Button { showNewMetric = true } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.body)
                        }
                    }
                }

                // Error
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                // Danger zone
                if !isNew {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete Plan", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Plan" : "Edit Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save") { save() }
                        .disabled(title.isEmpty || isSaving)
                        .bold()
                }
            }
            .sheet(isPresented: $showNewMetric) {
                MetricEditorView(initialMetric: nil) { newMetric in
                    metrics.append(newMetric)
                }
            }
            .sheet(isPresented: editingMetricPresented) {
                if let idx = editingMetricIndex, metrics.indices.contains(idx) {
                    MetricEditorView(initialMetric: metrics[idx]) { updated in
                        metrics[idx] = updated
                        editingMetricIndex = nil
                    }
                }
            }
            .confirmationDialog("Delete this plan?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deletePlan() }
            }
            .onAppear { populateFields() }
        }
    }

    private var editingMetricPresented: Binding<Bool> {
        Binding(
            get: { editingMetricIndex != nil },
            set: { if !$0 { editingMetricIndex = nil } }
        )
    }

    // MARK: - Data

    private func populateFields() {
        guard let plan = initialPlan else { return }
        title = plan.title
        description = plan.description ?? ""
        icon = plan.icon ?? ""
        category = plan.category ?? ""
        activeFrom = plan.active_from ?? ""
        activeUntil = plan.active_until ?? ""
        archived = plan.archived
        metrics = plan.metrics
    }

    private func buildPlan() -> CarnetAPI.CoachingPlan {
        CarnetAPI.CoachingPlan(
            id: initialPlan?.id ?? 0,
            title: title,
            description: description.isEmpty ? nil : description,
            icon: icon.isEmpty ? nil : icon,
            category: category.isEmpty ? nil : category,
            tags: initialPlan?.tags ?? [],
            active_from: activeFrom.isEmpty ? nil : activeFrom,
            active_until: activeUntil.isEmpty ? nil : activeUntil,
            archived: archived,
            metrics: metrics,
            note_slug: initialPlan?.note_slug,
            created_at: initialPlan?.created_at ?? "",
            updated_at: initialPlan?.updated_at ?? ""
        )
    }

    // MARK: - Actions

    private func save() {
        isSaving = true
        error = nil
        Task {
            do {
                let plan = buildPlan()
                if isNew {
                    _ = try await CarnetAPI.createCoachingPlan(plan)
                } else {
                    _ = try await CarnetAPI.updateCoachingPlan(plan)
                }
                await onSave()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func deletePlan() {
        guard let plan = initialPlan else { return }
        Task {
            try? await CarnetAPI.deleteCoachingPlan(id: plan.id)
            await onSave()
            dismiss()
        }
    }

    private func deleteMetrics(at offsets: IndexSet) {
        metrics.remove(atOffsets: offsets)
    }

    private func moveMetrics(from source: IndexSet, to destination: Int) {
        metrics.move(fromOffsets: source, toOffset: destination)
    }
}

// MARK: - Metric Row (read-only summary)

struct MetricRow: View {
    let metric: CarnetAPI.CoachingMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: iconForCategory(metric.signal_category))
                    .foregroundStyle(colorForCategory(metric.signal_category))
                    .frame(width: 20)

                Text(metric.pillar)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Text(metric.targetDescription)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.fill.tertiary)
                    .clipShape(Capsule())
            }

            // Details row
            HStack(spacing: 12) {
                Text(metric.signal_category)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let dur = metric.duration_min {
                    Text("≥ \(dur) min")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let match = metric.match, !match.fields.isEmpty {
                    let keys = match.fields.keys.sorted().joined(separator: ", ")
                    Text("match: \(keys)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
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
