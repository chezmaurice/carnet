import SwiftUI

struct MealListWidget: View {
    let widget: WidgetSpec
    let value: ResolvedMetric

    private var label: String { widget.params?["label"]?.stringValue ?? "Meals" }

    var body: some View {
        WidgetCard(title: label) {
            if case .meals(let entries) = value, !entries.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, meal in
                        if idx > 0 {
                            Rectangle()
                                .fill(CarnetTheme.rule)
                                .frame(height: 0.5)
                                .padding(.leading, CarnetTheme.mealTimeWidth + CarnetTheme.cardTitleSpacing)
                        }

                        HStack(alignment: .top, spacing: CarnetTheme.cardTitleSpacing) {
                            // Time column
                            VStack(alignment: .leading, spacing: 2) {
                                Text(timeString(meal.time))
                                    .font(CarnetTheme.mealTimeMono)
                                    .foregroundStyle(CarnetTheme.ink)
                                Text(meal.meal_type.uppercased())
                                    .font(CarnetTheme.mealTypeMicro)
                                    .foregroundStyle(CarnetTheme.inkMute)
                                    .tracking(0.6)
                            }
                            .frame(width: CarnetTheme.mealTimeWidth, alignment: .leading)

                            // Description
                            Text(meal.description)
                                .font(CarnetTheme.mealBody)
                                .foregroundStyle(CarnetTheme.inkSoft)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 6)
                    }
                }
            } else {
                Text("nothing logged yet")
                    .font(.system(size: 12.5, design: .serif))
                    .italic()
                    .foregroundStyle(CarnetTheme.inkHint)
            }
        }
    }

    private func timeString(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            let display = DateFormatter()
            display.dateFormat = "HH:mm"
            return display.string(from: date)
        }
        // Fallback: try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoString) {
            let display = DateFormatter()
            display.dateFormat = "HH:mm"
            return display.string(from: date)
        }
        // Fallback: extract HH:mm from the string
        if isoString.count >= 16 {
            let idx = isoString.index(isoString.startIndex, offsetBy: 11)
            let end = isoString.index(idx, offsetBy: 5)
            return String(isoString[idx..<end])
        }
        return isoString
    }
}
