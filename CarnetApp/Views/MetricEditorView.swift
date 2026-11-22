import SwiftUI

struct MetricEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let initialMetric: CarnetAPI.CoachingMetric?
    let onSave: (CarnetAPI.CoachingMetric) -> Void

    @State private var pillar = ""
    @State private var signalCategory = "sports"
    @State private var metricType: MetricType = .frequency
    @State private var frequencyCount = 3
    @State private var frequencyUnit = "week"
    @State private var durationMin: String = ""
    @State private var maxPerDay: String = "1"
    @State private var matchEntries: [MatchEntry] = []

    private var isNew: Bool { initialMetric == nil }

    enum MetricType: String, CaseIterable {
        case frequency = "Frequency target"
        case enumerate = "Count only"
        case maxPerDay = "Maximum per day"
    }

    struct MatchEntry: Identifiable {
        let id = UUID()
        var field: String
        var values: String  // comma-separated
    }

    static let signalCategories = [
        "sports", "breathing", "meditation", "eating", "supplements",
        "alcohol", "cannabis", "measurement", "network",
        "reading", "writing", "watching", "listening",
    ]

    static let frequencyUnits = ["day", "week", "2weeks", "month"]

    var body: some View {
        NavigationStack {
            Form {
                // Identity
                Section("What to track") {
                    TextField("Pillar name", text: $pillar)
                        .font(.headline)

                    Picker("Signal category", selection: $signalCategory) {
                        ForEach(Self.signalCategories, id: \.self) { cat in
                            Label(cat, systemImage: iconForCategory(cat))
                                .tag(cat)
                        }
                    }
                }

                // Target type
                Section("Target") {
                    Picker("Type", selection: $metricType) {
                        ForEach(MetricType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch metricType {
                    case .frequency:
                        frequencyControls
                    case .enumerate:
                        Text("Signals will be counted with no target.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .maxPerDay:
                        HStack {
                            Text("Maximum")
                            Spacer()
                            TextField("1", text: $maxPerDay)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 50)
                            Text("/ day")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if metricType == .frequency {
                        HStack {
                            Text("Min duration")
                            Spacer()
                            TextField("—", text: $durationMin)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 50)
                            Text("min")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Match filters
                Section {
                    ForEach($matchEntries) { $entry in
                        HStack(spacing: 8) {
                            TextField("field", text: $entry.field)
                                .frame(width: 80)
                                .font(.caption)
                                .textFieldStyle(.roundedBorder)

                            TextField("value1, value2, ...", text: $entry.values)
                                .font(.caption)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .onDelete { matchEntries.remove(atOffsets: $0) }

                    Button {
                        matchEntries.append(MatchEntry(field: "", values: ""))
                    } label: {
                        Label("Add filter", systemImage: "plus.circle")
                            .font(.subheadline)
                    }
                } header: {
                    Text("Match Filters")
                } footer: {
                    Text("Narrow which signals count. E.g. field \"activity\", values \"running, cycling\".")
                        .font(.caption2)
                }
            }
            .navigationTitle(isNew ? "New Metric" : "Edit Metric")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .disabled(pillar.isEmpty)
                        .bold()
                }
            }
            .onAppear { populateFields() }
        }
    }

    private var frequencyControls: some View {
        HStack {
            Text("Target")
            Spacer()

            Stepper(value: $frequencyCount, in: 1...20) {
                Text("\(frequencyCount)")
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
            }
            .frame(width: 140)

            Text("/")
                .foregroundStyle(.secondary)

            Picker("", selection: $frequencyUnit) {
                ForEach(Self.frequencyUnits, id: \.self) { unit in
                    Text(unit).tag(unit)
                }
            }
            .labelsHidden()
            .frame(width: 100)
        }
    }

    // MARK: - Data

    private func populateFields() {
        guard let m = initialMetric else { return }
        pillar = m.pillar
        signalCategory = m.signal_category

        if m.enumerate == true {
            metricType = .enumerate
        } else if let max = m.max_per_day {
            metricType = .maxPerDay
            maxPerDay = "\(max)"
        } else {
            metricType = .frequency
            if let freq = m.frequency {
                parseFrequency(freq)
            }
        }

        if let dur = m.duration_min {
            durationMin = "\(dur)"
        }

        if let match = m.match {
            matchEntries = match.fields.map { key, values in
                MatchEntry(field: key, values: values.joined(separator: ", "))
            }
        }
    }

    private func parseFrequency(_ freq: String) {
        let parts = freq.split(separator: "/")
        if parts.count == 2 {
            frequencyCount = Int(parts[0]) ?? 3
            frequencyUnit = String(parts[1])
        }
    }

    private func save() {
        var metric = CarnetAPI.CoachingMetric(pillar: pillar, signal_category: signalCategory)

        switch metricType {
        case .frequency:
            metric.frequency = "\(frequencyCount)/\(frequencyUnit)"
            if let dur = Int(durationMin), dur > 0 {
                metric.duration_min = dur
            }
        case .enumerate:
            metric.enumerate = true
        case .maxPerDay:
            metric.max_per_day = Int(maxPerDay) ?? 1
        }

        // Build match
        let validEntries = matchEntries.filter { !$0.field.isEmpty && !$0.values.isEmpty }
        if !validEntries.isEmpty {
            var fields: [String: [String]] = [:]
            for entry in validEntries {
                let values = entry.values
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !values.isEmpty {
                    fields[entry.field] = values
                }
            }
            if !fields.isEmpty {
                metric.match = CarnetAPI.CoachingMetricMatch(fields: fields)
            }
        }

        onSave(metric)
        dismiss()
    }

    private func iconForCategory(_ cat: String) -> String {
        switch cat {
        case "sports": return "figure.run"
        case "breathing": return "wind"
        case "meditation": return "brain.head.profile"
        case "eating": return "fork.knife"
        case "supplements": return "pill.fill"
        case "alcohol": return "wineglass.fill"
        case "cannabis": return "leaf.fill"
        case "measurement": return "ruler.fill"
        case "network": return "person.2.fill"
        case "reading": return "book.fill"
        case "writing": return "pencil.line"
        case "watching": return "tv.fill"
        case "listening": return "headphones"
        default: return "circle.fill"
        }
    }
}
