import SwiftUI

/// What the share sheet shows. ShareViewController fills it from what was
/// shared and from the save as it goes; the view draws it, edits the note,
/// and once saved offers the member's other domains.
@Observable @MainActor
final class ShareModel {
    enum Kind { case article, document, book }
    enum Phase: Equatable {
        case editing
        case working(String)
        /// The sheet's last word before it closes: `ok` for a save that
        /// landed, otherwise something that waits or went wrong.
        case done(String, ok: Bool)
    }

    var kind: Kind = .article
    var title = ""
    var detail = ""
    var thumb: UIImage?
    /// Safari handed over the page as it is read, paywall and all.
    var fullPage = false
    /// A note goes on an article's fiche; a file has nowhere to keep it.
    var allowsNote = false
    var foldOpen = false
    var note = ""
    var canSave = false
    var phase: Phase = .editing

    /// Where the household filed the saved article (no tags to type: a
    /// domain is chosen for it), and the member's domains to change it to.
    /// No choices, nothing is shown — a member without domains.
    var filed: CarnetAPI.DomainChoice?
    var choices: [CarnetAPI.DomainChoice] = []
    /// The member opened the choice: the sheet stays until they are done.
    var choosing = false
    var filingError: String?
}

struct ShareSheetView: View {
    @Bindable var model: ShareModel
    let dictation: ShareDictation
    var onCancel: () -> Void
    var onSave: () -> Void
    /// Opening the choice (the sheet must not close under the finger).
    var onChoosing: () -> Void
    /// A domain chosen, or nil for none.
    var onChoose: (CarnetAPI.DomainChoice?) -> Void
    var onDone: () -> Void

    @FocusState private var noteFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if case let .done(message, ok) = model.phase {
                    done(message, ok: ok)
                } else {
                    ScrollView { content }
                        .scrollDismissesKeyboard(.interactively)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L("share.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isDone {
                    toolbar
                } else if model.choosing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("common.done"), action: onDone)
                    }
                }
            }
        }
        .task { if model.allowsNote { await dictation.probe() } }
    }

    private var isDone: Bool {
        if case .done = model.phase { return true }
        return false
    }

    private var isWorking: Bool {
        if case .working = model.phase { return true }
        return false
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(action: onCancel) { Image(systemName: "xmark") }
                .accessibilityLabel(L("common.cancel"))
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(action: { noteFocused = false; onSave() }) { Image(systemName: "checkmark") }
                .accessibilityLabel(L(saveLabel))
                .disabled(!model.canSave || isWorking || dictation.state != .idle)
                .modifier(ProminentWhereGlass())
        }
    }

    private var saveLabel: String {
        switch model.kind {
        case .article: "share.save"
        case .document: "share.save_document"
        case .book: "share.add_book"
        }
    }

    // MARK: - Editing

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            itemCard
            if model.fullPage {
                Label(L("share.full_page"), systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 4)
            }
            if model.allowsNote { fold }
            if case let .working(message) = model.phase {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(message).foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(.horizontal, 4)
            }
        }
        .padding(16)
    }

    private var itemCard: some View {
        HStack(spacing: 14) {
            Group {
                if let thumb = model.thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Image(systemName: placeholderSymbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.tertiarySystemGroupedBackground))
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(model.title.isEmpty ? "…" : model.title)
                    .font(.headline)
                    .lineLimit(3)
                if !model.detail.isEmpty {
                    Text(model.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(card)
    }

    private var placeholderSymbol: String {
        switch model.kind {
        case .article: "globe"
        case .document: "doc"
        case .book: "book.closed"
        }
    }

    // MARK: - The fold: why keep this

    private var fold: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("share.why"))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            foldCard
        }
    }

    private var foldCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { model.foldOpen.toggle() }
                noteFocused = model.foldOpen && model.note.isEmpty
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "text.alignleft")
                        .foregroundStyle(.secondary)
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(model.foldOpen ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(model.foldOpen ? .isSelected : [])

            if model.foldOpen {
                VStack(alignment: .leading, spacing: 12) {
                    noteField
                    if let line = micLine {
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding([.horizontal, .bottom], 16)
                .transition(.opacity)
            }
        }
        .background(card)
    }

    /// The note's first line under a closed fold, « Optional » when empty.
    private var summary: String {
        let note = model.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let line = note.split(whereSeparator: \.isNewline).first { return String(line) }
        let optional = L("share.optional")
        return optional.prefix(1).uppercased() + optional.dropFirst()
    }

    private var noteField: some View {
        ZStack(alignment: .bottomTrailing) {
            TextField(L("share.note"), text: $model.note, axis: .vertical)
                .lineLimit(4...8)
                .focused($noteFocused)
                .padding(12)
                .padding(.trailing, dictation.available ? 44 : 0)
                .background(Color(.tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if dictation.available { mic.padding(6) }
        }
    }

    private var mic: some View {
        Button { toggleDictation() } label: {
            ZStack {
                switch dictation.state {
                case .idle: Image(systemName: "mic")
                case .listening: Image(systemName: "stop.fill").font(.footnote)
                case .transcribing: ProgressView().controlSize(.small)
                }
            }
            .frame(width: 36, height: 36)
            .foregroundStyle(dictation.state == .listening ? Color.white : Color.accentColor)
            .background(Circle().fill(dictation.state == .listening ? Color.red : Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
        .disabled(dictation.state == .transcribing)
        .accessibilityLabel(L(dictation.state == .listening ? "share.stop_dictation" : "share.dictate"))
    }

    private var micLine: String? {
        switch dictation.state {
        case .listening: L("share.listening")
        case .transcribing: L("share.transcribing")
        case .idle: dictation.message
        }
    }

    private func toggleDictation() {
        Task {
            if dictation.state == .listening {
                guard let heard = await dictation.stop() else { return }
                let before = model.note.trimmingCharacters(in: .whitespacesAndNewlines)
                model.note = before.isEmpty ? heard : before + " " + heard
            } else {
                noteFocused = false
                await dictation.start()
            }
        }
    }

    // MARK: - Done

    private func done(_ message: String, ok: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: ok ? "checkmark.circle.fill" : "tray.and.arrow.down.fill")
                .font(.system(size: 54))
                .foregroundStyle(ok ? Color.green : Color.secondary)
                .symbolEffect(.bounce, value: ok)
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if ok, !model.choices.isEmpty { filedCard.padding(.horizontal, 16) }
        }
        .padding(.bottom, 40)
    }

    /// « Filed in Health · Change », and on Change the member's domains.
    private var filedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                // The domain's own mark when the system draws it, else a folder.
                Image(systemName: model.filed?.icon.flatMap { UIImage(systemName: $0) != nil ? $0 : nil } ?? "folder")
                    .foregroundStyle(.secondary)
                Group {
                    if let filed = model.filed {
                        Text(L("share.filed_in")) + Text(" ") + Text(filed.name).bold()
                    } else {
                        Text(L("share.filed_nowhere"))
                    }
                }
                .font(.subheadline)
                Spacer(minLength: 8)
                if !model.choosing {
                    Button(L(model.filed == nil ? "share.choose" : "share.change")) {
                        withAnimation(.snappy) { model.choosing = true }
                        onChoosing()
                    }
                    .font(.subheadline.weight(.medium))
                }
            }
            if model.choosing {
                FlowLayout(spacing: 8) {
                    ForEach(model.choices) { choice in choiceChip(choice.name, chosen: model.filed?.id == choice.id) { onChoose(choice) } }
                    choiceChip(L("share.no_domain"), chosen: false) { onChoose(nil) }
                }
            }
            if let error = model.filingError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(card)
    }

    private func choiceChip(_ name: String, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .foregroundStyle(chosen ? Color.white : Color.primary)
                .chip(fill: chosen ? Color.accentColor : Color(.tertiarySystemGroupedBackground))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}

private extension View {
    func chip(fill: Color) -> some View {
        font(.subheadline)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Capsule().fill(fill))
    }
}

/// The save button as iOS 26 draws a sheet's confirming action: a tinted
/// glass disc. Earlier systems keep their plain bar button.
private struct ProminentWhereGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content
        }
    }
}

/// Chips laid out in lines, wrapping at the width given.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            let gap: CGFloat = rows[rows.count - 1].items.isEmpty ? 0 : spacing
            rows[rows.count - 1].items.append(index)
            rows[rows.count - 1].width += size.width + gap
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
