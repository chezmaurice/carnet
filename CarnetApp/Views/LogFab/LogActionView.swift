import SwiftUI

struct LogActionView: View {
    let kind: LogKind
    let onDismiss: () -> Void

    @State private var text = ""
    @State private var items: [CarnetAPI.AggregatedSignal] = []
    @State private var isSending = false
    @State private var isLoading = true
    @State private var editingSignal: CarnetAPI.Signal? = nil
    @State private var toast: Toast? = nil
    @State private var swipedItemId: String? = nil
    @State private var sortBy: SortColumn = .last
    @State private var sortAscending = false
    @FocusState private var fieldFocused: Bool

    private enum SortColumn { case uses, last }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredItems: [CarnetAPI.AggregatedSignal] {
        let base: [CarnetAPI.AggregatedSignal]
        if text.isEmpty {
            base = items
        } else {
            let query = text.lowercased()
            base = items.filter { $0.details.lowercased().contains(query) }
        }
        return base.sorted { a, b in
            switch sortBy {
            case .uses:
                return sortAscending ? a.uses < b.uses : a.uses > b.uses
            case .last:
                let ta = a.last_timestamp ?? ""
                let tb = b.last_timestamp ?? ""
                return sortAscending ? ta < tb : ta > tb
            }
        }
    }

    private var maxUses: Int {
        items.map(\.uses).max() ?? 1
    }

    private var todayTotal: Int {
        items.reduce(0) { $0 + $1.today_count }
    }

    private var totalLogs: Int {
        items.reduce(0) { $0 + $1.uses }
    }

    var body: some View {
        if let category = kind.signalCategory {
            entryView(category: category)
        } else {
            placeholderView
        }
    }

    // MARK: - Data entry view

    private func entryView(category: String) -> some View {
        ZStack {
            CarnetTheme.bg
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Title row
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text("\(kind.label.lowercased()).")
                        .font(.system(size: 32, weight: .regular, design: .serif))
                        .italic()
                        .foregroundStyle(CarnetTheme.ink)

                    Image(systemName: kind.symbol)
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(CarnetTheme.inkMute)

                    Spacer()
                }
                .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 10)

                // Hairline
                Rectangle()
                    .fill(CarnetTheme.rule)
                    .frame(height: 0.5)

                // Entry/filter field (multiline)
                HStack(alignment: .bottom, spacing: 8) {
                    TextEditor(text: $text)
                        .font(.system(size: 15, design: .serif))
                        .italic()
                        .foregroundStyle(CarnetTheme.ink)
                        .scrollContentBackground(.hidden)
                        .focused($fieldFocused)
                        .frame(minHeight: 32, maxHeight: 100)
                        .fixedSize(horizontal: false, vertical: true)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("log \(kind.label.lowercased())...")
                                    .font(.system(size: 15, design: .serif))
                                    .italic()
                                    .foregroundStyle(CarnetTheme.inkHint)
                                    .allowsHitTesting(false)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                            }
                        }

                    if !trimmedText.isEmpty {
                        // Clear button
                        Button { text = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(CarnetTheme.inkMute)
                        }
                        .buttonStyle(.plain)

                        // Add chip
                        if isSending {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button { submit(category: category) } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "return")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text("ADD")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                }
                                .foregroundStyle(CarnetTheme.bg)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(CarnetTheme.ink)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                .padding(.vertical, 8)

                // Hairline
                Rectangle()
                    .fill(CarnetTheme.rule)
                    .frame(height: 0.5)

                // Column headers (USES and LAST are sort buttons)
                HStack(spacing: 0) {
                    Text("ITEM")
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        if sortBy == .uses { sortAscending.toggle() }
                        else { sortBy = .uses; sortAscending = false }
                    } label: {
                        HStack(spacing: 2) {
                            Text("USES")
                            if sortBy == .uses {
                                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 7, weight: .bold))
                            }
                        }
                        .foregroundStyle(sortBy == .uses ? CarnetTheme.ink : CarnetTheme.inkMute)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 52, alignment: .trailing)

                    Button {
                        if sortBy == .last { sortAscending.toggle() }
                        else { sortBy = .last; sortAscending = false }
                    } label: {
                        HStack(spacing: 2) {
                            Text("LAST")
                            if sortBy == .last {
                                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 7, weight: .bold))
                            }
                        }
                        .foregroundStyle(sortBy == .last ? CarnetTheme.ink : CarnetTheme.inkMute)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 56, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1)
                .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                .padding(.vertical, 6)

                Rectangle()
                    .fill(CarnetTheme.rule)
                    .frame(height: 0.5)

                // Item list
                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredItems) { item in
                                SwipeRevealRow(
                                    isActive: swipedItemId == item.id,
                                    onTap: { text = item.details },
                                    onEdit: { editItem(item, category: category) },
                                    onDelete: { deleteItem(item) },
                                    onSwipeChanged: { active in
                                        swipedItemId = active ? item.id : nil
                                    }
                                ) {
                                    itemRow(item)
                                }

                                Rectangle()
                                    .fill(CarnetTheme.rule)
                                    .frame(height: 0.5)
                                    .padding(.leading, CarnetTheme.pageHorizontalPadding)
                            }
                        }
                    }
                    .refreshable { await loadItems(category: category) }
                }

                // Footer
                HStack {
                    Text("\(totalLogs) logs \u{00b7} \(todayTotal) today")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CarnetTheme.inkHint)
                    Spacer()
                    Text("swipe \u{2192} edit \u{00b7} \u{2190} delete")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CarnetTheme.inkHint)
                }
                .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                .padding(.vertical, 8)
                .background(CarnetTheme.surface)
            }

            // Home FAB
            homeFab

            // Toast
            if let toast {
                VStack {
                    Spacer()
                    Text(toast.message)
                        .font(CarnetTheme.caption)
                        .foregroundStyle(toast.isError ? .red : CarnetTheme.bg)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(toast.isError ? Color.red.opacity(0.15) : CarnetTheme.ink)
                        .clipShape(Capsule())
                        .padding(.bottom, 48)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .task { await loadItems(category: category) }
        .onAppear { fieldFocused = true }
        .sheet(item: $editingSignal) { signal in
            SignalEditSheet(signal: signal) { _ in
                Task { await loadItems(category: category) }
            }
        }
    }

    // MARK: - Item row (3-column grid)

    private func itemRow(_ item: CarnetAPI.AggregatedSignal) -> some View {
        HStack(spacing: 0) {
            // Column 1: item + tags
            VStack(alignment: .leading, spacing: 3) {
                Text(item.details)
                    .font(CarnetTheme.subheadline)
                    .foregroundStyle(CarnetTheme.ink)
                    .lineLimit(1)

                if let tags = item.tags, !tags.isEmpty {
                    Text(tags.map { "#\($0)" }.joined(separator: " "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CarnetTheme.inkMute)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Column 2: uses count + frequency bar
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(item.uses)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(CarnetTheme.ink)
                    .monospacedDigit()

                GeometryReader { geo in
                    let barWidth = max(2, geo.size.width * CGFloat(item.uses) / CGFloat(max(maxUses, 1)))
                    HStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 1)
                            .fill(CarnetTheme.inkHint)
                            .frame(width: barWidth, height: 3)
                    }
                }
                .frame(height: 3)
            }
            .frame(width: 52)

            // Column 3: last-logged token
            Text(item.last_timestamp.map { Self.relativeDate($0) } ?? "\u{2014}")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(CarnetTheme.inkMute)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.vertical, 10)
    }

    // MARK: - Placeholder

    private var placeholderView: some View {
        ZStack {
            CarnetTheme.bg.ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(CarnetTheme.inkMute)
                Text(kind.label)
                    .font(CarnetTheme.headline)
                    .foregroundStyle(CarnetTheme.ink)
                Text("Coming soon")
                    .font(CarnetTheme.caption)
                    .foregroundStyle(CarnetTheme.inkHint)
            }

            homeFab
        }
    }

    // MARK: - Home FAB (matches dashboard + button)

    private var homeFab: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(CarnetTheme.bg)
                        .frame(width: CarnetTheme.fabSize, height: CarnetTheme.fabSize)
                        .background(CarnetTheme.ink)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(CarnetTheme.bg.opacity(0.08), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.22), radius: 15, y: 7)
                        .rotationEffect(.degrees(45))
                }
                .buttonStyle(.plain)
                .padding(.trailing, CarnetTheme.fabInset)
                .padding(.bottom, CarnetTheme.fabInset)
            }
        }
    }

    // MARK: - Actions

    private func submit(category: String) {
        let trimmed = trimmedText
        guard !trimmed.isEmpty else { return }

        isSending = true
        text = ""
        Task {
            do {
                let created = try await CarnetAPI.parseAndCreateSignal(text: trimmed, category: category)
                await loadItems(category: category)
                showToast("Logged: \(created.details)")
            } catch {
                showToast("Failed to log signal", isError: true)
            }
            isSending = false
        }
    }

    private func editItem(_ item: CarnetAPI.AggregatedSignal, category: String) {
        Task {
            do {
                let signals = try await CarnetAPI.listSignals(category: category, limit: 200)
                if let signal = signals.first(where: { $0.id == item.last_id }) {
                    editingSignal = signal
                }
            } catch {
                showToast("Failed to load signal", isError: true)
            }
        }
    }

    private func deleteItem(_ item: CarnetAPI.AggregatedSignal) {
        Task {
            do {
                try await CarnetAPI.deleteSignal(id: item.last_id)
                withAnimation {
                    items.removeAll { $0.details == item.details }
                }
                await loadItems(category: kind.signalCategory ?? "")
            } catch {
                showToast("Failed to delete", isError: true)
            }
        }
    }

    private func loadItems(category: String) async {
        let result = (try? await CarnetAPI.fetchAggregatedSignals(category: category)) ?? []
        items = result
        isLoading = false
    }

    // MARK: - Toast

    private struct Toast: Equatable {
        let message: String
        let isError: Bool
    }

    private func showToast(_ message: String, isError: Bool = false) {
        withAnimation { toast = Toast(message: message, isError: isError) }
        Task {
            try? await Task.sleep(for: .seconds(isError ? 3 : 2))
            withAnimation { toast = nil }
        }
    }

    // MARK: - Relative date formatting

    private static func relativeDate(_ raw: String) -> String {
        guard let date = parseDate(raw) else { return raw }
        let cal = Calendar.current
        let now = Date()

        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInYesterday(date) { return "yday" }

        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 0
        if days < 7 { return "\(days)d" }
        if days < 30 {
            let weeks = days / 7
            return "\(weeks)w"
        }
        if days < 365 {
            let months = days / 30
            return "\(months)mo"
        }
        let years = days / 365
        return "\(years)y"
    }

    private static func parseDate(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        let sqlite = DateFormatter()
        sqlite.dateFormat = "yyyy-MM-dd HH:mm:ss"
        sqlite.timeZone = TimeZone(identifier: "UTC")
        if let d = sqlite.date(from: raw) { return d }
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.timeZone = TimeZone(identifier: "UTC")
        return dateOnly.date(from: raw)
    }
}

// MARK: - Swipe Reveal Row

/// A row with flat colored panels behind it that reveal as the foreground slides.
/// Swipe right → blue EDIT panel reveals on the left.
/// Swipe left  → red DELETE panel reveals on the right.
/// Actions only trigger when the panel is fully revealed (label fully visible).
private struct SwipeRevealRow<Content: View>: View {
    let isActive: Bool
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onSwipeChanged: (Bool) -> Void
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @GestureState private var dragOffset: CGFloat = 0

    private let actionWidth: CGFloat = 80
    private let editColor = Color(red: 0x2f/255, green: 0x6f/255, blue: 0xd1/255)
    private let deleteColor = Color(red: 0xb8/255, green: 0x47/255, blue: 0x3a/255)

    private var currentOffset: CGFloat {
        let total = offset + dragOffset
        // Rubber-band beyond action width
        if total > actionWidth {
            return actionWidth + (total - actionWidth) * 0.3
        }
        if total < -actionWidth {
            return -actionWidth + (total + actionWidth) * 0.3
        }
        return total
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Background panels — always present, revealed by sliding the foreground
            HStack(spacing: 0) {
                // Left: Edit (blue)
                editColor
                    .frame(width: max(0, currentOffset))
                    .overlay(alignment: .center) {
                        if currentOffset > 30 {
                            VStack(spacing: 2) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 14, weight: .medium))
                                Text("Edit")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                            }
                            .foregroundStyle(.white)
                        }
                    }

                Spacer()

                // Right: Delete (red)
                deleteColor
                    .frame(width: max(0, -currentOffset))
                    .overlay(alignment: .center) {
                        if currentOffset < -30 {
                            VStack(spacing: 2) {
                                Image(systemName: "trash")
                                    .font(.system(size: 14, weight: .medium))
                                Text("Delete")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                            }
                            .foregroundStyle(.white)
                        }
                    }
            }

            // Foreground content
            content()
                .background(CarnetTheme.bg)
                .offset(x: currentOffset)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .updating($dragOffset) { value, state, _ in
                            state = value.translation.width
                        }
                        .onChanged { _ in
                            onSwipeChanged(true)
                        }
                        .onEnded { value in
                            let final = offset + value.translation.width
                            withAnimation(.easeOut(duration: 0.25)) {
                                if final >= actionWidth {
                                    // Fully revealed → commit edit
                                    offset = 0
                                    onSwipeChanged(false)
                                    onEdit()
                                } else if final <= -actionWidth {
                                    // Fully revealed → commit delete
                                    offset = 0
                                    onSwipeChanged(false)
                                    onDelete()
                                } else {
                                    // Not far enough → snap back
                                    offset = 0
                                    onSwipeChanged(false)
                                }
                            }
                        }
                )
                .onTapGesture {
                    if offset != 0 {
                        withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
                        onSwipeChanged(false)
                    } else {
                        onTap()
                    }
                }
        }
        .clipped()
        .onChange(of: isActive) { _, active in
            if !active && offset != 0 {
                withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
            }
        }
    }
}

// MARK: - Signal Edit Sheet

private struct SignalEditSheet: View {
    let signal: CarnetAPI.Signal
    let onSave: (CarnetAPI.Signal) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var details: String
    @State private var timestamp: Date
    @State private var metadataRows: [(key: String, value: String)]
    @State private var isSaving = false

    init(signal: CarnetAPI.Signal, onSave: @escaping (CarnetAPI.Signal) -> Void) {
        self.signal = signal
        self.onSave = onSave
        _details = State(initialValue: signal.details)
        _timestamp = State(initialValue: Self.parseTimestamp(signal.timestamp))
        _metadataRows = State(initialValue: {
            guard let meta = signal.metadata else { return [] }
            return meta.sorted(by: { $0.key < $1.key }).map { (key: $0.key, value: "\($0.value.value)") }
        }())
    }

    private static func parseTimestamp(_ raw: String?) -> Date {
        guard let raw else { return Date() }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        let sqlite = DateFormatter()
        sqlite.dateFormat = "yyyy-MM-dd HH:mm:ss"
        sqlite.timeZone = TimeZone.current
        if let d = sqlite.date(from: raw) { return d }
        return Date()
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Details") {
                    TextEditor(text: $details)
                        .font(.system(size: 14, design: .monospaced))
                        .frame(minHeight: 60)
                }

                Section("Timestamp") {
                    DatePicker("", selection: $timestamp)
                        .labelsHidden()
                }

                Section("Metadata") {
                    ForEach(metadataRows.indices, id: \.self) { i in
                        HStack(spacing: 8) {
                            TextField("key", text: Binding(
                                get: { metadataRows[i].key },
                                set: { metadataRows[i].key = $0 }
                            ))
                            .font(.system(size: 13, design: .monospaced))
                            .frame(width: 100)
                            .foregroundStyle(CarnetTheme.inkSoft)

                            TextField("value", text: Binding(
                                get: { metadataRows[i].value },
                                set: { metadataRows[i].value = $0 }
                            ))
                            .font(.system(size: 13, design: .monospaced))
                        }
                    }
                    .onDelete { metadataRows.remove(atOffsets: $0) }

                    Button {
                        metadataRows.append((key: "", value: ""))
                    } label: {
                        Label("Add field", systemImage: "plus")
                            .font(CarnetTheme.caption)
                    }
                }

                if let tags = signal.tags, !tags.isEmpty {
                    Section("Tags") {
                        Text(tags.joined(separator: ", "))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(CarnetTheme.inkSoft)
                    }
                }
            }
            .navigationTitle("Edit signal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                    }
                }
            }
        }
    }

    private func save() {
        isSaving = true
        let iso = ISO8601DateFormatter()
        let ts = iso.string(from: timestamp)
        var meta: [String: AnyCodable] = [:]
        for row in metadataRows where !row.key.isEmpty {
            if let num = Double(row.value) {
                meta[row.key] = AnyCodable(num)
            } else {
                meta[row.key] = AnyCodable(row.value)
            }
        }

        Task {
            if let updated = try? await CarnetAPI.updateSignal(
                id: signal.id,
                details: details,
                timestamp: ts,
                metadata: meta
            ) {
                onSave(updated)
            }
            isSaving = false
            dismiss()
        }
    }
}
