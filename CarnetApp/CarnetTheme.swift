import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Centralised design tokens for Carnet — **the Maurice theme**.
/// One warm ink on a warm paper, no accent colour, hairlines rather than boxes,
/// rounded shapes; Young Serif for display, the system font for text, system
/// mono for eyebrows and meta. Same palettes as the Maurice app
/// (`MauriceTheme.swift`), so the two read as one family. Token *names* are the
/// ones the Grid theme used, so every view keeps compiling; the values changed.
enum CarnetTheme {

    // MARK: - Palettes (mirrors MauriceTheme)

    /// Three surfaces; ink and rules derive from whether the palette is dark.
    struct Palette {
        let id: String
        let label: String
        let isDark: Bool
        let bg: UInt32
        let surface: UInt32
        let surfaceAlt: UInt32
    }

    static let lightPalettes: [Palette] = [
        Palette(id: "white", label: "White", isDark: false, bg: 0xffffff, surface: 0xffffff, surfaceAlt: 0xf6f6f4),
        Palette(id: "bone",  label: "Bone",  isDark: false, bg: 0xfafaf8, surface: 0xffffff, surfaceAlt: 0xf0f0ec),
        Palette(id: "ivory", label: "Ivory", isDark: false, bg: 0xf8f5ef, surface: 0xfefcf7, surfaceAlt: 0xefeae0),
        Palette(id: "cream", label: "Cream", isDark: false, bg: 0xf5efe6, surface: 0xfbf7f0, surfaceAlt: 0xf0e9dc),
        Palette(id: "stone", label: "Stone", isDark: false, bg: 0xefece6, surface: 0xf8f6f1, surfaceAlt: 0xe6e2d9),
        Palette(id: "sage",  label: "Sage",  isDark: false, bg: 0xecefe7, surface: 0xf5f7f0, surfaceAlt: 0xe2e7d9),
        Palette(id: "mist",  label: "Mist",  isDark: false, bg: 0xeceff3, surface: 0xf6f8fb, surfaceAlt: 0xdde3ea),
    ]

    static let darkPalettes: [Palette] = [
        Palette(id: "studio",   label: "Studio",   isDark: true, bg: 0x1f1c19, surface: 0x262320, surfaceAlt: 0x181614),
        Palette(id: "slate",    label: "Slate",    isDark: true, bg: 0x171a1d, surface: 0x1f2328, surfaceAlt: 0x0f1216),
        Palette(id: "forest",   label: "Forest",   isDark: true, bg: 0x141815, surface: 0x1c211c, surfaceAlt: 0x0e120e),
        Palette(id: "plum",     label: "Plum",     isDark: true, bg: 0x1c171c, surface: 0x241e26, surfaceAlt: 0x130f18),
        Palette(id: "espresso", label: "Espresso", isDark: true, bg: 0x1a1916, surface: 0x222019, surfaceAlt: 0x100f0c),
    ]

    /// Where the member's choice is kept. "auto" follows the system: Cream by
    /// day, Studio by night — the Maurice app's default pair.
    static let paletteKey = "carnet.palette"

    private static var namedPalette: Palette? {
        let id = UserDefaults.standard.string(forKey: paletteKey) ?? "auto"
        return (lightPalettes + darkPalettes).first { $0.id == id }
    }

    /// The palette in force for a trait collection. A named palette wins over
    /// the system appearance; `colorSchemeOverride` makes the system chrome
    /// (keyboard, sheets, status bar) follow it.
    static func palette(for traits: UITraitCollection) -> Palette {
        namedPalette ?? (traits.userInterfaceStyle == .dark ? darkPalettes[0] : lightPalettes[3])
    }

    /// The colour scheme a named palette implies; nil follows the system.
    static var colorSchemeOverride: ColorScheme? {
        namedPalette.map { $0.isDark ? .dark : .light }
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    private static func surfaceColor(_ pick: @escaping (Palette) -> UInt32) -> Color {
        Color(UIColor { rgb(pick(palette(for: $0))) })
    }

    /// The ink as a UIColor, for the UIKit text view. Light `#262320`, dark
    /// `#f0ebe2`. The dark ink reads lighter at the same alpha, hence the
    /// separate `dark` value where the two differ.
    static func uiInk(_ alpha: CGFloat = 1, dark darkAlpha: CGFloat? = nil) -> UIColor {
        UIColor { traits in
            palette(for: traits).isDark ? rgb(0xf0ebe2, alpha: darkAlpha ?? alpha)
                                        : rgb(0x262320, alpha: alpha)
        }
    }

    private static func inkAlpha(_ alpha: CGFloat, dark: CGFloat? = nil) -> Color {
        Color(uiInk(alpha, dark: dark))
    }

    // MARK: - Surface colors

    /// Page background — the paper
    static let bg = surfaceColor(\.bg)
    /// Raised surface (fields, dialogs before iOS 26)
    static let surface = surfaceColor(\.surface)
    /// Inset surface (placeholders, quoted blocks)
    static let surfaceAlt = surfaceColor(\.surfaceAlt)

    // MARK: - Ink (text + icon) colors

    /// Primary ink — full opacity
    static let ink = inkAlpha(1.0)
    /// Soft ink — labels, secondary text
    static let inkSoft = inkAlpha(0.62, dark: 0.65)
    /// Muted ink — captions, meta
    static let inkMute = inkAlpha(0.42, dark: 0.40)
    /// Hint ink — placeholders, empty states
    static let inkHint = inkAlpha(0.30, dark: 0.28)

    // MARK: - Rule / hairline colors

    /// Hairline
    static let rule = inkAlpha(0.10)
    /// Firm hairline — control and field outlines
    static let ruleHard = inkAlpha(0.18)
    /// A wash of ink behind marked text
    static let inkWash = inkAlpha(0.09, dark: 0.13)

    // MARK: - Emphasis — inverted ink, not a hue

    /// The theme has no accent colour. What the Grid painted red — the one
    /// primary action, an "on" control — is ink, with the paper as its text.
    static let accent = ink
    /// Foreground on `accent`: the paper.
    static let accentInk = bg

    // MARK: - Semantic

    /// Goal-met — the muted sage, the only semantic hue.
    static let good = Color(UIColor { palette(for: $0).isDark ? rgb(0x8aa88a) : rgb(0x5a735a) })

    // MARK: - Legacy aliases (map old names to new tokens)

    static let cardBackground = surface
    static let cardBorder = ruleHard
    static let textPrimary = ink
    static let textSecondary = inkSoft
    static let textTertiary = inkMute
    static let fillTertiary = rule

    static let positive = good
    static let warning = inkSoft
    static let negative = inkMute




    // MARK: - Typography (Young Serif · system · system mono)

    /// The one serif, bundled and registered at launch. Single weight.
    static let displayFamily = "YoungSerif-Regular"

    /// Display — titles and other moments. Young Serif has one weight, so
    /// `weight` is accepted for the call sites and ignored.
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(displayFamily, size: size)
    }
    /// Text and labels — the system font.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// Eyebrows, codes, timestamps, tabular numerals — system mono.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Large metric value
    static let metricLarge: Font = sans(28, weight: .semibold)
    /// Medium metric value
    static let metricMedium: Font = sans(24, weight: .semibold)
    /// Small metric / donut center
    static let metricSmall: Font = sans(13, weight: .semibold)
    /// Unit label beside a metric — mono
    static let unitLabel: Font = mono(11, weight: .regular)
    /// Body caption
    static let caption: Font = sans(11.5, weight: .regular)
    /// Mono-spaced numerals
    static let monoCaption: Font = mono(10.5).monospacedDigit()
    /// Mono-spaced numerals small
    static let monoCaptionSmall: Font = mono(10).monospacedDigit()
    /// Mono meta (timestamps, eyebrows)
    static let monoMeta: Font = mono(10)
    /// Headline (percentage, emphasis)
    static let headline: Font = sans(16, weight: .semibold)
    /// Subheadline
    static let subheadline: Font = sans(14, weight: .regular)
    /// Section header bold caption
    static let captionBold: Font = sans(12.5, weight: .semibold)
    /// Section label eyebrow — mono, uppercase
    static let sectionLabel: Font = mono(9.5, weight: .medium)
    /// Section label letter spacing (0.14em at 9.5pt)
    static let sectionLabelTracking: CGFloat = 1.33
    /// Screen header date eyebrow
    static let headerEyebrow: Font = mono(10, weight: .medium)
    /// Screen header title — serif display
    static let headerTitle: Font = display(32)
    /// Header title tracking
    static let headerTitleTracking: CGFloat = -0.16

    // MARK: - Spacing

    static let cardPadding: CGFloat = 16
    static let cardTitleSpacing: CGFloat = 8
    static let pageHorizontalPadding: CGFloat = 20
    static let rowSpacing: CGFloat = 12
    static let pageVerticalPadding: CGFloat = 8
    static let itemSpacing: CGFloat = 6
    static let tightSpacing: CGFloat = 4
    static let inlineSpacing: CGFloat = 2

    // MARK: - Corner radii — small on inline elements, generous on what floats

    static let cardCornerRadius: CGFloat = 14
    static let innerCornerRadius: CGFloat = 6
    /// Covers and thumbnails
    static let coverCornerRadius: CGFloat = 3
    /// Fields and dialogs
    static let fieldCornerRadius: CGFloat = 12
    /// Floating panels (glass footers, cards)
    static let panelCornerRadius: CGFloat = 30

    // MARK: - Sizes

    /// Hairline width — half a point, as in the Maurice app
    static let hairline: CGFloat = 0.5
    static let cardBorderWidth: CGFloat = 0.5
    static let legendDotSize: CGFloat = 6
    static let narrowBreakpoint: CGFloat = 375
    static let checkboxSize: CGFloat = 14
    static let checkboxBorderWidth: CGFloat = 1
    static let checkboxCornerRadius: CGFloat = 3
    static let skeletonOpacityMin: Double = 0.3
    static let skeletonOpacityMax: Double = 0.7
    static let skeletonAnimationDuration: Double = 0.8

    // MARK: - Entry field

    static let entryFieldHeight: CGFloat = 44

    // MARK: - FAB


    // MARK: - Row heights

    static let defaultRowHeight: CGFloat = 140
    static let narrativeRowHeight: CGFloat = 160

    // MARK: - Helpers

    /// Arc color: ink under goal, sage once met.
    static func progressColor(_ progress: Double) -> Color {
        progress >= 1.0 ? good : ink
    }

    /// Heatmap fill — binary: rule (off) or ink (on)
    static func heatmapColor(_ count: Int) -> Color {
        count > 0 ? ink : rule
    }

    /// Delta color — monochrome by default
    static func deltaColor(delta: Double, direction: String) -> Color {
        inkSoft
    }
}
