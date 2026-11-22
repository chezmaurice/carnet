import SwiftUI

/// The Maurice app, when it is on this device. Carnet declares `maurice` in
/// LSApplicationQueriesSchemes, so the answer is honest.
enum MauriceApp {
    static var installed: Bool {
        URL(string: "maurice://").map(UIApplication.shared.canOpenURL) ?? false
    }

    static func open(conversation id: String) {
        guard let url = URL(string: "maurice://conversations/\(id)") else { return }
        UIApplication.shared.open(url)
    }
}

/// Talking an entry over with Maurice: in the Maurice app — a conversation
/// already held about it, or a new one with the entry's fiche in context.
/// With none yet, the tap opens a new one directly; otherwise a short menu
/// offers the new one first, then the past ones, newest first.
///
/// Without the Maurice app on the device, the conversation is held here, in
/// Carnet's own thread (AskMauriceView), as it was before 19 October 2026.
struct MauriceHandoff: ViewModifier {
    /// The entry to talk about; nil while the screen has not resolved it yet.
    let entry: ShelfEntry?
    @Binding var trigger: Bool
    /// Carnet's own thread closed — `true` when something was kept from it.
    var onClose: (Bool) -> Void = { _ in }

    @State private var past: [EntryConversation] = []
    @State private var choosing = false
    @State private var inCarnet = false
    @State private var opening = false
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: trigger) {
                guard trigger else { return }
                trigger = false
                Task { await start() }
            }
            .overlay { if opening { ProgressView().tint(CarnetTheme.inkMute) } }
            .confirmationDialog("Talk with Maurice", isPresented: $choosing, titleVisibility: .visible) {
                Button("New conversation") { Task { await startNew() } }
                ForEach(past.prefix(6)) { c in
                    Button("\(c.displayTitle) · \(c.when)") { MauriceApp.open(conversation: c.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("In the Maurice app, with this entry in context.")
            }
            .fullScreenCover(isPresented: $inCarnet) {
                if let entry { AskMauriceView(entry: entry, onClose: onClose) }
            }
            .alert("Maurice could not be opened", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
    }

    private func start() async {
        guard entry != nil else { return }
        guard MauriceApp.installed else { inCarnet = true; return }
        opening = true
        defer { opening = false }
        do {
            past = try await GardenAPI.conversations(about: entry!)
        } catch {
            // Not knowing the past ones is no reason not to talk.
            past = []
        }
        if past.isEmpty { await startNew() } else { choosing = true }
    }

    private func startNew() async {
        guard let entry else { return }
        opening = true
        defer { opening = false }
        do {
            MauriceApp.open(conversation: try await MauriceAPI.open(from: entry.id))
        } catch {
            failure = error.localizedDescription
        }
    }
}

extension View {
    func mauriceHandoff(entry: ShelfEntry?, trigger: Binding<Bool>, onClose: @escaping (Bool) -> Void = { _ in }) -> some View {
        modifier(MauriceHandoff(entry: entry, trigger: trigger, onClose: onClose))
    }
}

// MARK: - On the fiche

/// The conversations held about an entry, on its fiche: one line each, and
/// under it what it came to. The summary is the fiche's own (a fragment),
/// written by the server once the conversation has settled — twenty minutes
/// after its last message — and written again when it goes on; nobody has to
/// ask for it. Before that, the line says so, and offers to write it now.
struct EntryConversationsSection: View {
    let entry: ShelfEntry
    let conversations: [EntryConversation]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                MauriceMark(size: 16)
                GridLabel(conversations.count == 1 ? "1 conversation with Maurice"
                                                   : "\(conversations.count) conversations with Maurice", size: 9.5)
            }
            ForEach(conversations) { ConversationLine(entry: entry, conversation: $0) }
        }
        .padding(.top, 6)
    }
}

private struct ConversationLine: View {
    let entry: ShelfEntry
    let conversation: EntryConversation

    @State private var summary: EntryConversation.Summary?
    @State private var writing = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.displayTitle)
                        .font(CarnetTheme.sans(14.5, weight: .medium))
                        .foregroundStyle(CarnetTheme.ink)
                        .lineLimit(2)
                    GridLabel(setting, size: 9)
                }
                Spacer(minLength: 0)
                if MauriceApp.installed {
                    Button { MauriceApp.open(conversation: conversation.id) } label: {
                        Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CarnetTheme.inkSoft)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open in Maurice")
                }
            }

            if let shown = summary ?? conversation.summary {
                ReplyText(markdown: shown.text, style: ReplyStyle(bodySize: 14.5, lineSpacing: 2.5))
                    .opacity(writing ? 0.5 : 1)
                if shown.stale, !writing {
                    Text("The conversation went on: this is updated once it settles.")
                        .font(CarnetTheme.sans(12)).foregroundStyle(CarnetTheme.inkMute)
                }
                // One that came out wrong is written again from the conversation.
                if !writing {
                    Button { Task { await write(force: true) } } label: {
                        Label("Rewrite", systemImage: "arrow.clockwise")
                            .font(CarnetTheme.sans(12, weight: .medium))
                            .foregroundStyle(CarnetTheme.inkSoft)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rewrite the summary")
                }
            } else if !writing {
                HStack(spacing: 10) {
                    Text("Maurice writes what came of it once the conversation has settled.")
                        .font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkMute)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { Task { await write() } } label: {
                        Text("Write it now")
                            .font(CarnetTheme.sans(13, weight: .medium))
                            .foregroundStyle(CarnetTheme.ink)
                            .underline(true, color: CarnetTheme.ruleHard)
                    }
                    .buttonStyle(.plain)
                }
            }
            if writing {
                HStack(spacing: 8) {
                    ProgressView().tint(CarnetTheme.inkMute)
                    Text("Maurice is writing it…").font(CarnetTheme.sans(13)).foregroundStyle(CarnetTheme.inkMute)
                }
            }
            if let failure {
                Text(failure).font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkSoft)
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
    }

    /// "Today · from this entry · 3 messages", or the Maurice it was held with.
    private var setting: String {
        let messages = conversation.messageCount == 1 ? "1 message" : "\(conversation.messageCount) messages"
        let place = conversation.maurice.map { "with \($0.name)" }
            ?? (conversation.via == "entry" ? "from this entry" : "in Maurice")
        return [conversation.when, place, messages].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func write(force: Bool = false) async {
        writing = true
        failure = nil
        defer { writing = false }
        do {
            summary = try await GardenAPI.conversationSummary(entry, conversation: conversation.id, force: force)
        } catch {
            failure = "Could not write the summary. \(error.localizedDescription)"
        }
    }
}
