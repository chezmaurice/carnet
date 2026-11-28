import SwiftUI

/// The question asked before anything a member gives Maurice reaches an AI
/// provider: which providers, where, what is sent, and that Maurice is an AI
/// whose answers can be wrong. The Maurice app's screen and words
/// (`AIConsentView` there). Shown after sign-in until the member answers, and
/// again when a provider appears that their yes does not cover; the member
/// sheet's *AI providers* row opens it to change the answer (`onClose` set).
struct AIConsentView: View {
    @Environment(AIConsentStore.self) private var consent
    @Environment(\.openURL) private var openURL
    /// Set when the member opened the screen themselves: they may leave it
    /// without answering again.
    var onClose: (() -> Void)? = nil

    @State private var busy = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    providerList
                    dataList
                    notes
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) { actions }
            .background(CarnetTheme.bg.ignoresSafeArea())
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("common.cancel"), action: onClose)
                    }
                }
            }
        }
        .tint(CarnetTheme.ink)
        .interactiveDismissDisabled(onClose == nil)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("ai.consent.title"))
                .font(CarnetTheme.display(26))
                .foregroundStyle(CarnetTheme.ink)
            if !consent.newProviders.isEmpty, consent.record?.status == "accepted" {
                Text(L("ai.consent.new_provider"))
                    .font(CarnetTheme.sans(14, weight: .medium))
                    .foregroundStyle(CarnetTheme.ink)
            }
            if let line = currentAnswer {
                Text(line)
                    .font(CarnetTheme.sans(14, weight: .medium))
                    .foregroundStyle(CarnetTheme.ink)
            }
            Text(L("ai.consent.intro"))
                .font(CarnetTheme.sans(15))
                .foregroundStyle(CarnetTheme.inkSoft)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The answer on file, said when the member comes back to change it.
    private var currentAnswer: String? {
        guard onClose != nil, let status = consent.record?.status else { return nil }
        return L(status == "accepted" ? "ai.consent.carnet.current.accepted" : "ai.consent.carnet.current.declined")
    }

    private var providerList: some View {
        let highlighted = Set(consent.newProviders.map(\.id))
        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel(L("ai.consent.providers.header"))
            if consent.providers.isEmpty {
                Text(L("ai.consent.providers.none"))
                    .font(CarnetTheme.sans(14)).foregroundStyle(CarnetTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(consent.providers) { p in
                HStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 13))
                        .foregroundStyle(CarnetTheme.inkSoft)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(CarnetTheme.sans(14.5, weight: .semibold)).foregroundStyle(CarnetTheme.ink)
                        if let place = p.place {
                            Text(place).font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkMute)
                        }
                    }
                    Spacer(minLength: 0)
                    if highlighted.contains(p.id) {
                        Text(L("ai.consent.new")).font(CarnetTheme.sans(11, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(CarnetTheme.inkWash))
                            .foregroundStyle(CarnetTheme.ink)
                    }
                }
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(CarnetTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CarnetTheme.rule, lineWidth: 0.5))
            }
        }
    }

    private static let dataRows: [(String, String)] = [
        ("text.bubble", "ai.consent.data.messages"),
        ("paperclip", "ai.consent.data.attachments"),
        ("books.vertical", "ai.consent.data.context"),
        ("envelope", "ai.consent.data.mail"),
        ("square.and.arrow.down", "ai.consent.data.imports"),
        ("moon.stars", "ai.consent.data.night"),
        ("mic", "ai.consent.data.dictation"),
    ]

    private var dataList: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(L("ai.consent.data.header"))
            ForEach(Self.dataRows, id: \.1) { icon, key in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 12.5))
                        .foregroundStyle(CarnetTheme.inkSoft)
                        .frame(width: 22)
                    Text(L(key))
                        .font(CarnetTheme.sans(14))
                        .foregroundStyle(CarnetTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("ai.consent.accuracy"), systemImage: "exclamationmark.bubble")
                .font(CarnetTheme.sans(13.5, weight: .medium))
                .foregroundStyle(CarnetTheme.ink)
            Text(L("ai.consent.local"))
                .font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkMute)
            Text(L("ai.consent.carnet.footer", L("privacy.section"), L("ai.consent.carnet.row")))
                .font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkMute)
            Button(L("ai.consent.privacy")) { openURL(URL(string: "https://www.chezmaurice.eu/privacy.html")!) }
                .font(CarnetTheme.sans(12.5, weight: .medium))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if failed {
                Text(L("ai.consent.carnet.failed"))
                    .font(CarnetTheme.sans(12.5)).foregroundStyle(CarnetTheme.inkSoft)
                    .multilineTextAlignment(.center)
            }
            Button { decide(true) } label: {
                Text(L("ai.consent.accept")).frame(maxWidth: 400)
            }
            .glassProminentButton()
            .controlSize(.large)
            Button { decide(false) } label: {
                Text(L("ai.consent.decline")).frame(maxWidth: 400)
            }
            .glassBorderedButton()
            .controlSize(.large)
        }
        .disabled(busy)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(CarnetTheme.bg)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(CarnetTheme.sans(11, weight: .semibold)).tracking(0.8)
            .foregroundStyle(CarnetTheme.inkMute)
    }

    private func decide(_ accept: Bool) {
        busy = true
        failed = false
        Task {
            let recorded = await consent.decide(accept: accept)
            busy = false
            failed = !recorded
            if recorded { onClose?() }
        }
    }
}
