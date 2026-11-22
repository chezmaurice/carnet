import SwiftUI

/// « Invite a friend as a guest »: the same QR / code / link screen as « Add
/// a device », worded for someone else. The friend who uses it joins this
/// household as a guest who sees only the member, and whom only the member
/// can share with (maurice/specs/cross-household-share.md, section A).
struct GuestInviteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var invite: CrossHouseholdAPI.GuestInvite?
    @State private var failure: String?
    @State private var state = "pending"

    private var link: String? {
        guard let invite else { return nil }
        if let link = invite.link, !link.isEmpty { return link }
        return Invitation(server: CarnetAPI.baseURL, code: Invitation.normalizedCode(invite.code) ?? invite.code).link
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text(L("guest.invite.sheet_title"))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    if state == "used" {
                        Label(L("guest.invite.done"), systemImage: "checkmark.circle.fill")
                            .font(.title3.weight(.medium))
                            .multilineTextAlignment(.center)
                            .frame(minHeight: 240)
                    } else if let invite, let link {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let left = AddDeviceSheet.remaining(invite.expires_at, now: ctx.date)
                            VStack(spacing: 18) {
                                if state == "expired" || (left == nil && Self.expired(invite.expires_at, now: ctx.date)) {
                                    Text(L("guest.invite.expired"))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .frame(minHeight: 240)
                                } else {
                                    QRCodeImage(text: link)
                                        .padding(14)
                                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        .frame(maxWidth: 260)
                                    Text(Invitation.normalizedCode(invite.code) ?? invite.code)
                                        .font(.title2.monospaced().weight(.medium))
                                        .tracking(3)
                                        .textSelection(.enabled)
                                    Text(left ?? Self.until(invite.expires_at).map { L("guest.invite.until", $0) } ?? "")
                                        .font(.footnote.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    if let url = URL(string: link) {
                                        ShareLink(item: url) { Label(L("guest.invite.share"), systemImage: "square.and.arrow.up") }
                                            .glassBorderedButton()
                                            .tint(CarnetTheme.ink)
                                    }
                                }
                            }
                        }
                    } else if let failure {
                        Text(failure).foregroundStyle(.red).multilineTextAlignment(.center).frame(minHeight: 240)
                    } else {
                        ProgressView().frame(minHeight: 240)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L("guest.invite.only_you"), systemImage: "person.2")
                        Label(L("guest.invite.maurice"), systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                .padding(24)
            }
            .navigationTitle(L("guest.invite"))
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
            invite = try await CrossHouseholdAPI.guestInvite()
        } catch CrossHouseholdAPI.Failure.offline {
            failure = L("guest.invite.offline")
        } catch CrossHouseholdAPI.Failure.forbidden {
            failure = L("guest.invite.refused")
        } catch CrossHouseholdAPI.Failure.unsupported {
            failure = L("guest.invite.unsupported")
        } catch CrossHouseholdAPI.Failure.refused(let code) {
            failure = code
        } catch {
            failure = error.localizedDescription
        }
        // Watched while the sheet is open, as « Add a device » does.
        guard let code = invite?.code else { return }
        while !Task.isCancelled && state == "pending" {
            try? await Task.sleep(for: .seconds(3))
            if let next = await CrossHouseholdAPI.guestInviteState(code), next != "pending" {
                withAnimation { state = next }
            }
        }
    }

    /// « 10 novembre » — a guest invitation lasts days, not minutes.
    private static func until(_ iso: String) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) ?? ServerDate.parse(iso) else { return nil }
        return date.formatted(.dateTime.day().month(.wide).locale(AppLanguage.locale))
    }

    private static func expired(_ iso: String, now: Date) -> Bool {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) ?? ServerDate.parse(iso) else { return false }
        return date <= now
    }
}
