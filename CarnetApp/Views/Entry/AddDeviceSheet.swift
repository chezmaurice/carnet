import SwiftUI
import CoreImage.CIFilterBuiltins

/// « Add a device »: a code that signs this same member in on another device,
/// as a QR big enough to scan across a table, the code to type as a fallback,
/// the time left, and the link to send. Watches the code and says so once the
/// other device is in. Any member, for themselves — as in the Maurice app.
///
/// « Connect a browser » is the same code for the « Save to Carnet »
/// extension in Chrome, Brave or Firefox: the link to paste instead of a QR
/// (a computer has no camera pointed at the phone), with a button to copy it.
struct AddDeviceSheet: View {
    var forBrowser = false

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var code: CarnetAPI.DeviceCode?
    @State private var failure: String?
    @State private var state = "pending"

    private var invitation: Invitation? {
        code.map { Invitation(server: CarnetAPI.baseURL, code: Invitation.normalizedCode($0.code) ?? $0.code) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text(L(forBrowser ? "browser.connect.line" : "devices.add.sheet_title"))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if state == "used" {
                    Label(L("devices.add.done"), systemImage: "checkmark.circle.fill")
                        .font(.title3.weight(.medium))
                        .frame(minHeight: 240)
                } else if state == "expired" {
                    Text(L("devices.add.expired"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 240)
                } else if forBrowser, let invitation, let code {
                    Text(invitation.link)
                        .font(.callout.monospaced())
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(Self.remaining(code.expires_at, now: ctx.date) ?? "")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button { copy(invitation.link) } label: {
                        Label(L(copied ? "browser.connect.copied" : "browser.connect.copy"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .glassBorderedButton()
                    .tint(CarnetTheme.ink)
                } else if let invitation, let code {
                    // Dark modules on white, whatever the theme: a scanner wants contrast.
                    QRCodeImage(text: invitation.link)
                        .padding(14)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .frame(maxWidth: 260)
                    Text(invitation.code)
                        .font(.title2.monospaced().weight(.medium))
                        .tracking(3)
                        .textSelection(.enabled)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(Self.remaining(code.expires_at, now: ctx.date) ?? "")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let url = URL(string: invitation.link) {
                        ShareLink(item: url) { Label(L("devices.add"), systemImage: "square.and.arrow.up") }
                            .glassBorderedButton()
                            .tint(CarnetTheme.ink)
                    }
                } else if let failure {
                    Text(failure).foregroundStyle(.red).multilineTextAlignment(.center).frame(minHeight: 240)
                } else {
                    ProgressView().frame(minHeight: 240)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle(L(forBrowser ? "browser.connect" : "devices.add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
                }
            }
        }
        .task { await run() }
    }

    private func run() async {
        do {
            code = try await CarnetAPI.deviceCode()
        } catch {
            failure = error.localizedDescription
            return
        }
        guard let raw = code?.code else { return }
        while !Task.isCancelled && state == "pending" {
            try? await Task.sleep(for: .seconds(2))
            if let next = await CarnetAPI.deviceCodeState(raw), next != "pending" {
                withAnimation { state = next }
            }
        }
        if state == "used" {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { dismiss() }
        }
    }

    private func copy(_ link: String) {
        UIPasteboard.general.string = link
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { copied = false }
        }
    }

    /// « Valid for 4:32 » while the code lasts.
    static func remaining(_ iso: String, now: Date) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        let left = Int(date.timeIntervalSince(now))
        guard left > 0, left < 3_600 else { return nil }
        return L("devices.add.countdown", String(format: "%d:%02d", left / 60, left % 60))
    }
}

/// A QR code drawn crisp at any size.
struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel(text)
        }
    }

    private static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
