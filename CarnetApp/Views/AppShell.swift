import SwiftUI

/// Top-level app shell: the list of entries is the root; the member's button
/// in its header opens the short menu (what is not an entry), whose head opens
/// the household/member sheet.
struct AppShell: View {
    @Environment(CarnetSession.self) private var session
    @State private var showMemberSwitch = false

    /// The views below are rebuilt for each member (`.id`): what they hold in
    /// memory was read as the previous one, and a member switch happens in a
    /// sheet over them, which neither recreates nor reappears them.
    private var memberIdentity: String { "\(session.currentHouseholdId ?? "")#\(session.activeMemberId ?? "")" }

    var body: some View {
        ShelfView(onIdentity: { showMemberSwitch = true })
            .id(memberIdentity)
            .sheet(isPresented: $showMemberSwitch) { MemberSwitchSheet() }
    }
}

// MARK: - Member badge (per-member color — the only chrome hue)

struct MemberBadge: View {
    let member: CarnetAPI.Member?
    var size: CGFloat = 34

    // The member's picture when they have one; their initial on their
    // colour otherwise, and while the picture loads.
    var body: some View {
        Group {
            if let url = member?.avatarImageURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().interpolation(.high).scaledToFill()
                    } else {
                        initial
                    }
                }
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initial: some View {
        Text(member?.initial ?? "·")
            .font(CarnetTheme.sans(size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(member?.color ?? CarnetTheme.inkMute)
    }
}
