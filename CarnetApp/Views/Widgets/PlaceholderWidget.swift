import SwiftUI

struct PlaceholderWidget: View {
    let typeName: String

    var body: some View {
        WidgetCard(title: nil) {
            VStack(spacing: CarnetTheme.itemSpacing) {
                Image(systemName: "puzzlepiece")
                    .font(.title2)
                    .foregroundStyle(CarnetTheme.inkMute)
                Text("Widget not yet supported")
                    .font(CarnetTheme.caption)
                    .foregroundStyle(CarnetTheme.inkSoft)
                Text(typeName)
                    .font(CarnetTheme.unitLabel)
                    .foregroundStyle(CarnetTheme.inkMute)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
