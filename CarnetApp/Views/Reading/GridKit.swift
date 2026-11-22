import SwiftUI

/// The shared primitives every screen is built from. They read `CarnetTheme`
/// — the Maurice theme: mono eyebrows, hairlines, rounded shapes, no accent
/// colour. The `Grid` prefix is the name they were born with under the earlier
/// theme; it is kept so the call sites did not have to move.

// MARK: - Eyebrow (system mono, uppercase, tracked)

struct GridLabel: View {
    let text: String
    var size: CGFloat = 10
    var color: Color = CarnetTheme.inkMute
    var weight: Font.Weight = .medium

    init(_ text: String, size: CGFloat = 10, color: Color = CarnetTheme.inkMute, weight: Font.Weight = .medium) {
        self.text = text; self.size = size; self.color = color; self.weight = weight
    }

    var body: some View {
        Text(text.uppercased())
            .font(CarnetTheme.mono(size, weight: weight))
            .tracking(size * 0.12)
            .foregroundStyle(color)
    }
}

// MARK: - Hairline rule

struct GridRule: View {
    var hard: Bool = false
    var body: some View {
        Rectangle()
            .fill(hard ? CarnetTheme.ruleHard : CarnetTheme.rule)
            .frame(height: CarnetTheme.hairline)
    }
}

// MARK: - Progress bar (ink; sage once a goal is met)

struct GridBar: View {
    let value: Double
    var width: CGFloat? = nil
    var height: CGFloat = 2
    /// Turn the bar sage when full — for goals. Off for neutral progress
    /// (reading, summaries), which stays ink.
    var accentWhenFull: Bool = true

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(CarnetTheme.ruleHard)
                Capsule()
                    .fill(accentWhenFull && value >= 1 ? CarnetTheme.good : CarnetTheme.ink)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Filter chip

struct GridChip: View {
    let text: String
    var on: Bool = false
    var accent: Bool = false

    var body: some View {
        Text(text)
            .font(CarnetTheme.sans(12.5, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? CarnetTheme.accentInk : CarnetTheme.inkSoft)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(on ? CarnetTheme.ink : Color.clear))
            .overlay(Capsule().strokeBorder(on ? CarnetTheme.ink : CarnetTheme.ruleHard,
                                            lineWidth: CarnetTheme.hairline))
    }
}

// MARK: - Placeholder cover (serif letter on the inset surface)

struct GridCover: View {
    var letter: String = "A"
    var width: CGFloat = 46
    var height: CGFloat = 64

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CarnetTheme.coverCornerRadius, style: .continuous)
        Text(letter)
            .font(CarnetTheme.display(height * 0.3))
            .foregroundStyle(CarnetTheme.inkMute)
            .frame(width: width, height: height)
            .background(CarnetTheme.surfaceAlt, in: shape)
            .overlay(shape.strokeBorder(CarnetTheme.rule, lineWidth: CarnetTheme.hairline))
    }
}

// MARK: - State of the shared side (shape, not hue)

/// Whether what the member wrote to share is still a draft or is published.
/// A hollow ring for a draft, a solid disc for published; nothing at all when
/// nothing is written, so the caller simply leaves the mark out.
enum EntryState { case draft, published }

struct StateMark: View {
    let state: EntryState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .strokeBorder(state == .draft ? CarnetTheme.inkSoft : CarnetTheme.ink, lineWidth: 1.25)
                .background(Circle().fill(state == .published ? CarnetTheme.ink : Color.clear))
                .frame(width: 7, height: 7)
            GridLabel(state == .draft ? "Draft" : "Published", size: 9.5,
                      color: state == .draft ? CarnetTheme.inkSoft : CarnetTheme.ink)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Screen header (flush-left serif title, optional kicker/back/right)

struct GridHeader<Right: View>: View {
    let title: String
    var kicker: String? = nil
    var back: (() -> Void)? = nil
    var menu: (() -> Void)? = nil
    /// Shows the active member's badge in the menu slot instead of ☰ — the
    /// minimal scope's only chrome; tapping it opens the member/household sheet.
    var identity: (() -> Void)? = nil
    @ViewBuilder var right: () -> Right
    @Environment(CarnetSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let identity {
                    Button(action: identity) {
                        MemberBadge(member: session.activeMember, size: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Member and household")
                }
                if let menu {
                    Button(action: menu) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(CarnetTheme.inkSoft)
                    }
                    .buttonStyle(.plain)
                }
                if let back {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(CarnetTheme.inkSoft)
                    }
                    .buttonStyle(.plain)
                }
                if let kicker { GridLabel(kicker) }
                Spacer(minLength: 0)
                right()
            }
            Text(title)
                .font(CarnetTheme.headerTitle)
                .tracking(CarnetTheme.headerTitleTracking)
                .foregroundStyle(CarnetTheme.ink)
        }
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }
}

extension GridHeader where Right == EmptyView {
    init(title: String, kicker: String? = nil, back: (() -> Void)? = nil, menu: (() -> Void)? = nil) {
        self.init(title: title, kicker: kicker, back: back, menu: menu, right: { EmptyView() })
    }
}

// MARK: - Icon button

/// The glyph every icon control shares — a Button here, a Menu label
/// elsewhere. A circle under a hairline on the page; a bare glyph inside a
/// bar or a panel (see `gridControlChrome`).
struct GridIconGlyph: View {
    let systemName: String
    var on: Bool = false
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.44, weight: .regular))
            .gridControlChrome(size: size, on: on)
    }
}

struct GridIconButton: View {
    let systemName: String
    var primary: Bool = false
    var size: CGFloat = 34
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            GridIconGlyph(systemName: systemName, on: primary, size: size)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Screen title (in the content, under the floating chrome)

/// The flush-left serif title with its eyebrow, laid in the scrolling content
/// so the floating chrome (`gridTopChrome`) passes over it. The screens that
/// still draw a `GridHeader` keep the title in the header instead.
struct GridTitle: View {
    let title: String
    var kicker: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let kicker { GridLabel(kicker) }
            Text(title)
                .font(CarnetTheme.headerTitle)
                .tracking(CarnetTheme.headerTitleTracking)
                .foregroundStyle(CarnetTheme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }
}

// MARK: - Top chrome row (leading group · trailing group)

/// The row the floating chrome shows: a leading group (back, or the member
/// badge) and a trailing group of actions, each in its own capsule.
struct GridChromeRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    /// False when built with a leading group only — an empty glass capsule
    /// still draws as a sliver, so the trailing bar is left out entirely.
    var hasTrailing = true

    var body: some View {
        HStack(spacing: 12) {
            GlassBar { leading() }
            Spacer(minLength: 0)
            if hasTrailing { GlassBar { trailing() } }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

extension GridChromeRow where Trailing == EmptyView {
    init(@ViewBuilder leading: @escaping () -> Leading) {
        self.init(leading: leading, trailing: { EmptyView() }, hasTrailing: false)
    }
}

/// A chevron back button for the chrome row.
struct GridBackButton: View {
    var size: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GridIconGlyph(systemName: "chevron.left", size: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }
}

// MARK: - Segmented pair (Text | Summary) for the readers' panel

/// One segment of a two-state toggle: a pill that lifts off the track when
/// on. The track is drawn by `GridSegmentPair`.
struct GridSegment: View {
    let label: String
    let on: Bool
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button { if enabled { action() } } label: {
            Text(label)
                .font(CarnetTheme.sans(13, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? CarnetTheme.ink : (enabled ? CarnetTheme.inkSoft : CarnetTheme.inkHint))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background {
                    if on {
                        Capsule().fill(CarnetTheme.surface)
                            .overlay(Capsule().strokeBorder(CarnetTheme.rule, lineWidth: CarnetTheme.hairline))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// The track the segments sit in: a capsule of faint ink, so it reads on the
/// paper and inside a glass panel alike.
struct GridSegmentPair<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 2) { content() }
            .padding(3)
            .background(Capsule().fill(CarnetTheme.rule))
    }
}

// MARK: - Hiding the keyboard from a search field

/// The keyboard glyph inside an empty search field: hides the keyboard and
/// leaves the search open.
struct HideKeyboardButton: View {
    var focus: FocusState<Bool>.Binding

    var body: some View {
        Button { focus.wrappedValue = false } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.system(size: 15))
                .foregroundStyle(CarnetTheme.inkMute)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hide keyboard")
    }
}

// MARK: - Search in the bottom chrome

/// The shelf search: a magnifier alone at the trailing edge that, when tapped,
/// morphs into a full-width field with a close button — iOS 26's minimized
/// search toolbar behaviour. Before iOS 26 the same two states, without glass.
struct GridSearchBar: View {
    @Binding var searching: Bool
    @Binding var query: String
    let placeholder: String
    @Namespace private var ns
    @FocusState private var focused: Bool

    var body: some View {
        // The spacer stays outside the glass container: inside it, the
        // container hugged the button and its hit area drifted off the glyph.
        HStack(spacing: 0) {
            if !searching { Spacer(minLength: 0) }
            GlassGroup(spacing: 8) {
                if searching {
                    fieldState
                } else {
                    // Glass on the button, not its label — that is where the
                    // system samples put it, and where hit-testing stays whole.
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) { searching = true }
                    } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .glassControl(size: 44, morph: "search", namespace: ns)
                    .accessibilityLabel("Search")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .onChange(of: searching) { _, on in focused = on; if !on { query = "" } }
    }

    @ViewBuilder private var fieldState: some View {
        let field = HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(CarnetTheme.inkMute)
            TextField(placeholder, text: $query)
                .font(CarnetTheme.sans(15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.search)
            if focused && query.isEmpty { HideKeyboardButton(focus: $focused) }
            // The whole height of the bar, not the 16-point glyph: a thumb
            // aiming at the cross landed on the row above.
            Button {
                withAnimation(.easeOut(duration: 0.25)) { searching = false }
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(CarnetTheme.inkMute)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
        }
        .padding(.leading, 14).padding(.trailing, 2)
        .frame(height: 44)
        if #available(iOS 26.0, *) {
            field
                .glassEffect(.regular, in: Capsule())
                .glassEffectID("search", in: ns)
        } else {
            field
                .background(Capsule().fill(CarnetTheme.surface))
                .overlay(Capsule().strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
        }
    }
}

// MARK: - Primary / secondary button (capsule)
//
// Primary is inverted ink — ink fill, the paper as its text — and there is one
// per screen: it is the only opaque thing among the glass. Secondary is a
// hairline capsule.

struct GridButton: View {
    let title: String
    var systemImage: String? = nil
    var primary: Bool = false
    var full: Bool = false
    var small: Bool = false
    /// A secondary button whose action cannot be taken back: red letters.
    var destructive: Bool = false
    var action: () -> Void = {}

    // A disabled button says so by itself, and stays readable: muted ink on a
    // faint wash under a hairline. Fading the whole button instead put paper-
    // coloured letters on a pale capsule — a label nobody could read.
    @Environment(\.isEnabled) private var enabled
    private var filled: Bool { primary && enabled }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: small ? 12 : 14)) }
                Text(title).font(CarnetTheme.sans(small ? 12.5 : 14, weight: .semibold))
            }
            .frame(maxWidth: full ? .infinity : nil)
            .padding(.horizontal, small ? 14 : 18)
            .padding(.vertical, small ? 9 : 13)
            .foregroundStyle(!enabled ? CarnetTheme.inkMute : primary ? CarnetTheme.accentInk : destructive ? Color.red : CarnetTheme.ink)
            .background(Capsule().fill(filled ? CarnetTheme.accent
                                       : primary ? CarnetTheme.ink.opacity(0.07) : Color.clear))
            .overlay(Capsule().strokeBorder(filled ? Color.clear : CarnetTheme.ruleHard,
                                            lineWidth: CarnetTheme.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Standard states

/// Centered loading spinner on the page background.
struct GridLoading: View {
    var body: some View {
        ProgressView().tint(CarnetTheme.inkMute)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CarnetTheme.bg)
    }
}

/// Centered error / empty message.
struct GridMessage: View {
    let text: String
    var systemImage: String = "exclamationmark.triangle"
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(CarnetTheme.inkMute)
            Text(text)
                .font(CarnetTheme.subheadline)
                .foregroundStyle(CarnetTheme.inkSoft)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CarnetTheme.bg)
    }
}

// MARK: - Sort menu (shared by the shelves and the garden)
//
// Every list here has a natural default order — nearly always "what I touched
// last" — that is right often enough never to need choosing and wrong often
// enough to need changing. One control: the axes, a tick on the active one,
// and the default named as such so coming back to it is never a guess. The
// choice is stored by the host in @AppStorage, so it survives a launch.

protocol GridSortChoice: RawRepresentable, CaseIterable, Hashable where RawValue == String {
    /// The order the list starts in, and the one the menu marks as default.
    static var defaultChoice: Self { get }
    var label: String { get }
}

struct GridSortMenu<Choice: GridSortChoice>: View {
    @Binding private var choice: Choice
    private let size: CGFloat

    /// Binds to the host's `@AppStorage` string. A stored value no build still
    /// offers falls back to the default, rather than leaving the list in an
    /// order the menu ticks nothing for.
    init(raw: Binding<String>, size: CGFloat = 32) {
        self._choice = Binding(
            get: { Choice(rawValue: raw.wrappedValue) ?? Choice.defaultChoice },
            set: { raw.wrappedValue = $0.rawValue },
        )
        self.size = size
    }

    private func label(_ c: Choice) -> String {
        c == Choice.defaultChoice ? "\(c.label) · default" : c.label
    }

    var body: some View {
        let on = choice != Choice.defaultChoice
        return Menu {
            Picker("Sort", selection: $choice) {
                ForEach(Array(Choice.allCases), id: \.self) { c in
                    Text(label(c)).tag(c)
                }
            }
        } label: {
            // Same chrome as GridIconButton, filled when the list is NOT in its
            // default order — a surprising order should read as a setting, not
            // as a bug.
            GridIconGlyph(systemName: "arrow.up.arrow.down", on: on, size: size)
        }
        .accessibilityLabel("Sort")
    }
}
