import SwiftUI

// The ground of the way in: the app icon's own background, its blocks, tiled
// behind the welcome screen and « Who's here? » — the same rule in Maurice and
// Carnet, iOS and Android (export/<app>/background-tile).
//
//   - The tile repeats, never stretches: 320 pt a side, eight blocks of 40,
//     from the top-left corner (`carnet-tile`, the 1024 PNG brought to 960 px
//     and set at @3x).
//   - Carnet's tile is dark in both modes — it is the icon's — and never
//     veiled (Maurice's light tile is veiled at 55 % in dark mode, on its side).
//   - Nothing is written on the tile itself: everything sits on one card,
//     420 pt wide at most, radius 28, padding 24, 20 from the screen's edges,
//     in glass (the regular material before iOS 26); the text in it follows
//     the system's mode. No tile on sheets, dialogs, the scanner or loading.

/// The tiled icon background, full bleed.
struct EntryBackdrop: View {
    var body: some View {
        Image("carnet-tile")
            .resizable(resizingMode: .tile)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

extension View {
    /// The one card the way in sits on, over the tile.
    func entryCard() -> some View {
        modifier(EntryCard())
    }

    /// The entry screens' ground: the tile behind.
    func entryBackdrop() -> some View {
        background { EntryBackdrop() }
    }
}

private struct EntryCard: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    func body(content: Content) -> some View {
        let padded = content
            .padding(24)
            .frame(maxWidth: 420)
        Group {
            if #available(iOS 26.0, *) {
                padded.glassEffect(.regular, in: shape)
            } else {
                padded.background(.regularMaterial, in: shape)
            }
        }
        .padding(.horizontal, 20)
    }
}
