import SwiftUI

struct WidgetSkeleton: View {
    @State private var opacity = CarnetTheme.skeletonOpacityMin

    var body: some View {
        RoundedRectangle(cornerRadius: CarnetTheme.innerCornerRadius)
            .fill(CarnetTheme.rule)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: CarnetTheme.skeletonAnimationDuration).repeatForever(autoreverses: true)) {
                    opacity = CarnetTheme.skeletonOpacityMax
                }
            }
    }
}
