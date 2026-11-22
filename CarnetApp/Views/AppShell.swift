import SwiftUI

/// Top-level app shell — a sidebar drawer (port of the design's TDrawer) hosting
/// the three peer roles (Log · Dashboards · Content). The drawer is a custom
/// overlay rather than a `NavigationSplitView`: reliable on iPhone, and it
/// doesn't churn/cancel the section views' loads the way the split view did.
struct AppShell: View {
    let layoutService: LayoutService
    let metricService: MetricService

    @Environment(CarnetSession.self) private var session
    @State private var section: NavSection = .reading
    @State private var drawerOpen = false
    @State private var showMemberSwitch = false

    var body: some View {
        switch CarnetScope.current {
        case .minimal: minimalShell
        case .full: drawerShell
        }
    }

    /// The views below are rebuilt for each member (`.id`): what they hold in
    /// memory was read as the previous one, and a member switch happens in a
    /// sheet over them, which neither recreates nor reappears them.
    private var memberIdentity: String { "\(session.currentHouseholdId ?? "")#\(session.activeMemberId ?? "")" }

    /// The list of entries is the root; the member's button in its header opens
    /// the short menu (what is not an entry), whose head opens the
    /// household/member sheet.
    private var minimalShell: some View {
        ShelfView(onIdentity: { showMemberSwitch = true })
            .id(memberIdentity)
            .sheet(isPresented: $showMemberSwitch) { MemberSwitchSheet() }
    }

    private var drawerShell: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                sectionView
                    .id(memberIdentity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if drawerOpen {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .onTapGesture { closeDrawer() }
                        .transition(.opacity)

                    AppDrawer(
                        active: section,
                        onSelect: { select($0) },
                        onMemberTap: { drawerOpen = false; showMemberSwitch = true }
                    )
                    .frame(width: min(geo.size.width * 0.82, 360))
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(CarnetTheme.ruleHard).frame(width: 1).ignoresSafeArea()
                    }
                    .transition(.move(edge: .leading))
                    .zIndex(1)
                }
            }
        }
        .sheet(isPresented: $showMemberSwitch) { MemberSwitchSheet() }
    }

    @ViewBuilder private var sectionView: some View {
        let openMenu = { withAnimation(.easeOut(duration: 0.22)) { drawerOpen = true } }
        switch section {
        case .dashboards:
            DashboardView(layoutID: "daily-health", layoutService: layoutService,
                          metricService: metricService, onMenu: openMenu)
        case .reading:
            LibraryView(onMenu: openMenu)
        case .garden:
            GardenView(onMenu: openMenu)
        case .upload:
            UploadSection(onMenu: openMenu)
        default:
            ComingSoonSection(section: section, onMenu: openMenu)
        }
    }

    private func select(_ s: NavSection) {
        section = s
        closeDrawer()
    }
    private func closeDrawer() {
        withAnimation(.easeOut(duration: 0.2)) { drawerOpen = false }
    }
}

// MARK: - Sections

enum NavSection: String, CaseIterable, Identifiable {
    case log, notes, dreams, upload, dashboards, reading, garden, tasks, calendar
    var id: String { rawValue }

    var label: String {
        switch self {
        case .log: return "Log"
        case .notes: return "New note"
        case .dreams: return "Dreams"
        case .upload: return "Upload"
        case .dashboards: return "Dashboards"
        case .reading: return "Reading"
        case .garden: return "Notes"
        case .tasks: return "Tasks"
        case .calendar: return "Calendar"
        }
    }

    var symbol: String {
        switch self {
        case .log: return "plus"
        case .notes: return "pencil"
        case .dreams: return "moon"
        case .upload: return "arrow.up.doc"
        case .dashboards: return "square.grid.2x2"
        case .reading: return "book"
        case .garden: return "leaf"
        case .tasks: return "checkmark"
        case .calendar: return "calendar"
        }
    }

    /// Grouped exactly as the design drawer: Capture / Review / Plan.
    static let groups: [(String, [NavSection])] = [
        ("Capture", [.log, .notes, .dreams, .upload]),
        ("Review", [.dashboards, .reading, .garden]),
        ("Plan", [.tasks, .calendar]),
    ]

    /// Sections that are live today; the rest render a placeholder.
    var isLive: Bool { self == .dashboards || self == .reading || self == .garden || self == .upload }
}

// MARK: - Drawer

private struct AppDrawer: View {
    let active: NavSection
    let onSelect: (NavSection) -> Void
    let onMemberTap: () -> Void
    @Environment(CarnetSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Member / household header
            Button(action: onMemberTap) {
                HStack(spacing: 11) {
                    MemberBadge(member: session.activeMember, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.activeMember?.display_name ?? "Sign in")
                            .font(CarnetTheme.sans(15, weight: .semibold))
                            .foregroundStyle(CarnetTheme.ink)
                        GridLabel(session.currentHouseholdName, size: 9)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11)).foregroundStyle(CarnetTheme.inkMute)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            GridRule()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(NavSection.groups.enumerated()), id: \.offset) { _, group in
                        Text(group.0.uppercased())
                            .font(CarnetTheme.mono(9, weight: .semibold))
                            .tracking(1.3)
                            .foregroundStyle(CarnetTheme.inkMute)
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                        ForEach(group.1) { s in
                            DrawerRow(section: s, active: s == active) { onSelect(s) }
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CarnetTheme.surface)
    }
}

private struct DrawerRow: View {
    let section: NavSection
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: section.symbol)
                    .font(.system(size: 17))
                    .frame(width: 20)
                    .foregroundStyle(active ? CarnetTheme.ink : CarnetTheme.inkSoft)
                Text(section.label)
                    .font(CarnetTheme.sans(15, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? CarnetTheme.ink : CarnetTheme.inkSoft)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .background(active ? CarnetTheme.surfaceAlt : Color.clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(active ? CarnetTheme.accent : Color.clear)
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

// MARK: - Placeholder for not-yet-built sections

private struct ComingSoonSection: View {
    let section: NavSection
    let onMenu: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            GridHeader(title: section.label, kicker: "Carnet", menu: onMenu)
            GridRule()
            GridMessage(text: "\(section.label) is coming soon.", systemImage: section.symbol)
        }
        .background(CarnetTheme.bg)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }
}
