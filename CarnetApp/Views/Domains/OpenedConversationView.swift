import SwiftUI

/// A conversation Maurice opened on his own, read in Carnet: his first
/// message (and what followed, if the member already answered from the
/// Maurice app). Opening it marks it read — the unread dot and the
/// household's badge follow. Carnet has no chat: answering is a tap to the
/// Maurice app when it is installed, and a line saying so when it is not.
struct OpenedConversationView: View {
    let conversationId: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var detail: ConversationDetail?
    @State private var loading = true
    @State private var error: String?

    /// The Maurice app's URL, when a build that answers to a scheme is
    /// installed. Declared in Info.plist's LSApplicationQueriesSchemes.
    private var mauriceURL: URL? { URL(string: "maurice://conversations/\(conversationId)") }
    private var canOpenMaurice: Bool {
        guard let u = mauriceURL else { return false }
        return UIApplication.shared.canOpenURL(u)
    }

    var body: some View {
        Group {
            if loading {
                GridLoading()
            } else if let error {
                GridMessage(text: error)
            } else if let detail {
                thread(detail)
            }
        }
        .background(CarnetTheme.bg)
        .gridTopChrome { GridChromeRow { GridBackButton { dismiss() } } }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private func thread(_ d: ConversationDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GridLabel("Opened by Maurice", size: 9.5, color: CarnetTheme.inkSoft)
                    .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                Text(d.title ?? "Maurice")
                    .font(CarnetTheme.display(24, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(CarnetTheme.ink)
                    .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                    .padding(.top, 6)
                if let at = d.created_at {
                    Text(ServerDate.absolute(at))
                        .font(CarnetTheme.mono(10))
                        .foregroundStyle(CarnetTheme.inkMute)
                        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                        .padding(.top, 6)
                }

                GridRule().padding(.top, 16)

                ForEach(d.messages) { m in
                    MessageBlock(message: m)
                    GridRule()
                }

                replyFooter
                    .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                    .padding(.top, 20)
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder private var replyFooter: some View {
        if canOpenMaurice, let u = mauriceURL {
            GridButton(title: "Reply in Maurice", systemImage: "arrow.up.forward.app", primary: true) {
                openURL(u)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                GridLabel("To reply", size: 9.5)
                Text("Carnet reads what Maurice wrote; answering him is done in the Maurice app, where this conversation is waiting under the same title.")
                    .font(CarnetTheme.sans(13))
                    .foregroundStyle(CarnetTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func load() async {
        do {
            let d = try await DomainsAPI.conversation(id: conversationId)
            detail = d
            error = nil
            loading = false
            // Read now — the same gesture the Maurice app makes on opening.
            try? await DomainsAPI.markRead(conversationId: conversationId)
        } catch {
            if error.isCancellation { loading = false; return }
            self.error = "Couldn't load this conversation.\n\(error.localizedDescription)"
            loading = false
        }
    }
}

/// One message of the thread: Maurice's in the page's ink, the member's
/// set apart by a label. Its markdown is set as one text, selectable from
/// end to end (`ReplyText`).
private struct MessageBlock: View {
    let message: ConversationMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                GridLabel(message.isMaurice ? "Maurice" : "You", size: 9.5,
                          color: message.isMaurice ? CarnetTheme.inkSoft : CarnetTheme.inkMute)
                if let at = message.created_at {
                    GridLabel(ServerDate.age(at), size: 9.5)
                }
            }
            ReplyText(markdown: message.content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.vertical, 16)
        .background(message.isMaurice ? Color.clear : CarnetTheme.surfaceAlt)
    }
}
