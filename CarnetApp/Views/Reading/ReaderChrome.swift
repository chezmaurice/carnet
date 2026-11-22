import SwiftUI

// The pieces the two readers share: the heading above the text, the Text |
// Summary switch, the Aa control, and the fields of their sheets. The book
// reader and the article reader stay two thin views (see ArticleReaderView);
// what they draw is the same.

// MARK: - Heading above the text

/// Eyebrow, serif title, meta line. The first thing in the text's own flow
/// (`HighlightableText`'s header), scrolling away with it.
struct ReaderHeading: View {
    let eyebrow: String
    let title: String
    var meta: String? = nil
    var titleLines = 2
    /// Side margin. Zero when the heading sits inside a text that has its own.
    var inset: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GridLabel(eyebrow).lineLimit(1)
            Text(title)
                .font(CarnetTheme.display(26))
                .foregroundStyle(CarnetTheme.ink)
                .lineLimit(titleLines)
                .fixedSize(horizontal: false, vertical: true)
            if let meta { GridLabel(meta).padding(.top, 2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, inset)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }
}

// MARK: - Chrome that steps aside

extension View {
    /// A reader's bar, out of the way while the text is read: slid off its
    /// edge and faded, its room kept so the text does not move under it.
    func readerChrome(hidden: Bool, edge: VerticalEdge) -> some View {
        self
            .offset(y: hidden ? (edge == .top ? -140 : 160) : 0)
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }
}

// MARK: - Text | Summary

struct ReaderModeSwitch: View {
    @Binding var mode: ReaderMode
    var summaryEnabled: Bool

    var body: some View {
        GridSegmentPair {
            GridSegment(label: "Text", on: mode == .full) { mode = .full }
            GridSegment(label: "Summary", on: mode == .summary, enabled: summaryEnabled) { mode = .summary }
        }
    }
}

// MARK: - Aa

/// Cycles the three reading sizes; the choice is shared by both readers.
struct ReaderFontButton: View {
    @Binding var raw: Int

    var body: some View {
        Button {
            raw = (ReaderFontSize(rawValue: raw) ?? .medium).next.rawValue
        } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: 16))
                .gridControlChrome(size: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Text size")
    }
}

// MARK: - A text field for sheets

extension View {
    /// The look of an editable field in a sheet: the palette surface in a
    /// rounded rectangle under a hairline.
    func carnetField() -> some View {
        let shape = RoundedRectangle(cornerRadius: CarnetTheme.fieldCornerRadius, style: .continuous)
        return self
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(CarnetTheme.surface, in: shape)
            .overlay(shape.strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
    }
}
