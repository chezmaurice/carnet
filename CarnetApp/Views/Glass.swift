import SwiftUI

// MARK: - Liquid Glass (iOS 26+), surface and hairline before
//
// Same rule as the Maurice app: glass on everything that floats over the content
// (the two header groups, the bottom panel, the controls that live in them,
// sheets), never on content: text, rows and covers stay flat on the paper.
//
// The deployment target (iOS 17) is why everything is behind `#available`;
// before iOS 26 every helper keeps the same shapes — circles, capsules, a
// rounded panel — filled with the palette surface under a hairline.
//
// Same shape as Maurice's Glass.swift: helpers on View, a group container,
// and the system button styles behind one switch.

// MARK: Environment — "you are inside glass chrome"

private struct GlassChromeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a `GlassBar` or a glass footer on iOS 26: controls drop
    /// their square border and render as bare glyphs, the glass around them
    /// being the chrome. False before iOS 26 and outside any bar.
    var glassChrome: Bool {
        get { self[GlassChromeKey.self] }
        set { self[GlassChromeKey.self] = newValue }
    }
}

/// Whether this build runs on Liquid Glass. One place to ask.
enum Glass {
    static var isAvailable: Bool {
        if #available(iOS 26.0, *) { return true } else { return false }
    }
}

// MARK: - Floating chrome over scrolling content

extension View {
    /// Chrome pinned to the top, content scrolling beneath. On iOS 26 a
    /// `safeAreaBar`, which registers the bar for the scroll edge effect that
    /// keeps its controls legible; before, a `safeAreaInset` painted with the
    /// page background so the square chrome sits on solid paper.
    func gridTopChrome<C: View>(@ViewBuilder _ content: @escaping () -> C) -> some View {
        modifier(GridChrome(edge: .top, chrome: content))
    }

    /// Chrome pinned to the bottom, content scrolling beneath. Same split.
    func gridBottomChrome<C: View>(@ViewBuilder _ content: @escaping () -> C) -> some View {
        modifier(GridChrome(edge: .bottom, chrome: content))
    }
}

private struct GridChrome<C: View>: ViewModifier {
    let edge: VerticalEdge
    @ViewBuilder let chrome: () -> C

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: edge, spacing: 0) { chrome() }
        } else {
            content.safeAreaInset(edge: edge, spacing: 0) {
                chrome().background(CarnetTheme.bg)
            }
        }
    }
}

// MARK: - A group of controls in one capsule

/// A row of controls sharing one capsule — the iOS 26 toolbar-group idiom
/// (back on its own at the leading edge, the actions together at the trailing
/// edge). Glass on iOS 26; the palette surface under a hairline before. The
/// controls inside render as bare glyphs either way.
struct GlassBar<Content: View>: View {
    var spacing: CGFloat = 2
    @ViewBuilder var content: () -> Content

    var body: some View {
        let row = HStack(spacing: spacing) { content() }
            .padding(.horizontal, 4)
            .frame(minHeight: 44)
        if #available(iOS 26.0, *) {
            row.glassEffect(.regular, in: Capsule())
                .environment(\.glassChrome, true)
        } else {
            row.background(Capsule().fill(CarnetTheme.surface))
                .overlay(Capsule().strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
                .environment(\.glassChrome, true)
        }
    }
}

/// Neighbouring glass shapes that should blend and morph as one — iOS 26's
/// `GlassEffectContainer`; a plain group before.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Footer panel, control chrome, sheets, buttons

extension View {
    /// A panel that floats over the page, inset from the edges, its controls
    /// rendered bare: glass on iOS 26, a material under a hairline before.
    func glassFooter() -> some View { modifier(GlassFooter()) }

    /// One control's chrome. Inside a bar or a panel the control is a bare
    /// glyph — `on` fills an ink circle behind it. On the page it is a circle
    /// under a hairline, ink-filled when on.
    func gridControlChrome(size: CGFloat, on: Bool = false, round: Bool = false) -> some View {
        modifier(GridControlChrome(size: size, on: on, round: round))
    }

    /// A standalone glass control (not in a bar): interactive glass in a
    /// circle on iOS 26; the hairline circle before. For the one-off buttons that
    /// float alone, like the search magnifier.
    func glassControl(size: CGFloat, on: Bool = false, morph: String? = nil,
                      namespace: Namespace.ID? = nil) -> some View {
        modifier(GlassControl(size: size, on: on, morph: morph, namespace: namespace))
    }

    /// The root of a sheet's content. Apple asks that sheets keep the system's
    /// glass background, so on iOS 26 this paints nothing; before, the page
    /// background the sheets always had.
    func glassSheetBackground() -> some View { modifier(GlassSheetBackground()) }

    /// `.buttonStyle(.bordered)` that turns to the system's glass style on 26+.
    func glassBorderedButton() -> some View { modifier(GlassBorderedButton(prominent: false)) }
    /// `.buttonStyle(.borderedProminent)` that turns to glass on 26+.
    func glassProminentButton() -> some View { modifier(GlassBorderedButton(prominent: true)) }

    /// A dialog card (PIN prompt, invite code): glass on iOS 26, the surface
    /// under a hairline before — no drop shadow on either.
    func glassCard() -> some View { modifier(GlassCard()) }
}

private struct GlassFooter: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CarnetTheme.panelCornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content
                .padding(.horizontal, 6)
                .glassEffect(.regular, in: shape)
                .environment(\.glassChrome, true)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
        } else {
            content
                .padding(.horizontal, 6)
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
                .environment(\.glassChrome, true)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
        }
    }
}

private struct GridControlChrome: ViewModifier {
    let size: CGFloat
    let on: Bool
    let round: Bool
    @Environment(\.glassChrome) private var glass

    func body(content: Content) -> some View {
        if glass {
            content
                .foregroundStyle(on ? CarnetTheme.accentInk : CarnetTheme.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(on ? CarnetTheme.accent : Color.clear).padding(4))
                .contentShape(Circle())
        } else {
            content
                .foregroundStyle(on ? CarnetTheme.accentInk : CarnetTheme.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(on ? CarnetTheme.accent : Color.clear))
                .overlay(Circle().strokeBorder(on ? CarnetTheme.accent : CarnetTheme.ruleHard,
                                               lineWidth: CarnetTheme.hairline))
                .contentShape(Circle())
        }
    }
}

private struct GlassControl: ViewModifier {
    let size: CGFloat
    let on: Bool
    let morph: String?
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .foregroundStyle(on ? CarnetTheme.accentInk : CarnetTheme.ink)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glassEffect(on ? .regular.tint(CarnetTheme.accent).interactive() : .regular.interactive(),
                             in: Circle())
                .modifier(GlassIdentity(morph: morph, namespace: namespace))
        } else {
            content.gridControlChrome(size: size, on: on)
        }
    }
}

@available(iOS 26.0, *)
struct GlassIdentity: ViewModifier {
    let morph: String?
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let morph, let namespace {
            content.glassEffectID(morph, in: namespace)
        } else {
            content
        }
    }
}

private struct GlassSheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.background(CarnetTheme.bg)
        }
    }
}

private struct GlassBorderedButton: ViewModifier {
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { label(content).buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            if prominent { label(content).buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        }
    }

    // The prominent button is tinted with ink, which is light in dark mode;
    // the system's white label on it could not be read. Its text is the paper.
    @ViewBuilder private func label(_ content: Content) -> some View {
        if enabled { content.foregroundStyle(CarnetTheme.accentInk) } else { content }
    }
}

private struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        } else {
            let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
            content
                .background(CarnetTheme.surface, in: shape)
                .overlay(shape.strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
        }
    }
}
