import SwiftUI

struct ComingSoonView: View {
    let title: String

    var body: some View {
        VStack(spacing: CarnetTheme.rowSpacing) {
            Image(systemName: "hammer")
                .font(.largeTitle)
                .foregroundStyle(CarnetTheme.inkSoft)
            Text(title)
                .font(CarnetTheme.headline)
            Text("Coming soon")
                .font(CarnetTheme.subheadline)
                .foregroundStyle(CarnetTheme.inkSoft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
