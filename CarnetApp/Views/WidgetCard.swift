import SwiftUI

/// Card chrome shared by all widgets — matches the design's WidgetShell.
/// Surface background, 0.5px rule-hard border, 6px corner radius.
struct WidgetCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: CarnetTheme.cardTitleSpacing) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(CarnetTheme.widgetTitle)
                    .foregroundStyle(CarnetTheme.inkMute)
                    .textCase(.uppercase)
                    .tracking(CarnetTheme.widgetTitleTracking)
            }
            content()
        }
        .padding(CarnetTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CarnetTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: CarnetTheme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: CarnetTheme.cardCornerRadius)
                .stroke(CarnetTheme.ruleHard, lineWidth: CarnetTheme.cardBorderWidth)
        )
    }
}
