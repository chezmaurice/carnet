import SwiftUI

struct LogFabView: View {
    let onSelect: (LogKind) -> Void

    @State private var open = false
    @State private var logged: LogKind?
    @State private var flashPhase = false
    @State private var toast: (code: String, time: String)?

    private let items = LogKind.radialItems

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Backdrop
            if open {
                Color.black.opacity(0.07)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)
            }

            // Radial tiles
            ForEach(Array(items.enumerated()), id: \.element.id) { index, kind in
                let angle = tileAngle(index: index)
                let offset = tileOffset(angle: angle)
                let isLogged = logged == kind
                let flashed = isLogged && flashPhase

                Button {
                    guard logged == nil else { return }
                    confirmTile(kind)
                } label: {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(flashed ? CarnetTheme.bg : CarnetTheme.ink)
                    .frame(width: CarnetTheme.fabItemSize, height: CarnetTheme.fabItemSize)
                    .background(flashed ? CarnetTheme.ink : CarnetTheme.surface)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(CarnetTheme.ruleHard, lineWidth: flashed ? 0 : 0.5)
                    )
                    .shadow(color: .black.opacity(open ? 0.14 : 0), radius: 11, y: 4)
                }
                .buttonStyle(.plain)
                .offset(x: open ? offset.x : 0, y: open ? offset.y : 0)
                .opacity(open ? 1 : 0)
                .animation(
                    .easeOut(duration: 0.15).delay(open ? Double(index) * 0.018 : Double(items.count - 1 - index) * 0.01),
                    value: open
                )
            }

            // Toast
            if let toast {
                HStack(spacing: 4) {
                    Text(toast.code)
                        .font(CarnetTheme.monoMeta)
                        .foregroundStyle(CarnetTheme.bg)
                    Text(toast.time)
                        .font(CarnetTheme.monoMeta)
                        .foregroundStyle(CarnetTheme.bg.opacity(0.6))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(CarnetTheme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .offset(y: -(CarnetTheme.fabSize + 14))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            // FAB button
            Button {
                if open { close() } else { withAnimation(.easeOut(duration: 0.2)) { open = true } }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(CarnetTheme.bg)
                    .frame(width: CarnetTheme.fabSize, height: CarnetTheme.fabSize)
                    .background(CarnetTheme.ink)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(CarnetTheme.bg.opacity(0.08), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.22), radius: 15, y: 7)
                    .rotationEffect(.degrees(open ? 45 : 0))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Geometry

    private func tileAngle(index: Int) -> Double {
        let start = -88.0
        let end = -188.0
        let step = (end - start) / Double(items.count - 1)
        return start + step * Double(index)
    }

    private func tileOffset(angle: Double) -> CGPoint {
        let rad = angle * .pi / 180
        let r = Double(CarnetTheme.fabRadius)
        return CGPoint(
            x: cos(rad) * r,
            y: sin(rad) * r
        )
    }

    // MARK: - Actions

    private func close() {
        withAnimation(.easeOut(duration: 0.2)) { open = false }
    }

    private func confirmTile(_ kind: LogKind) {
        logged = kind

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timeStr = formatter.string(from: Date())

        // Flash twice: on → off → on → off
        let step = 0.08
        withAnimation(.easeInOut(duration: step)) { flashPhase = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + step) {
            withAnimation(.easeInOut(duration: step)) { flashPhase = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * 2) {
            withAnimation(.easeInOut(duration: step)) { flashPhase = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * 3) {
            withAnimation(.easeInOut(duration: step)) { flashPhase = false }
            logged = nil

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                close()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        toast = (kind.code, timeStr)
                    }
                    onSelect(kind)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            toast = nil
                        }
                    }
                }
            }
        }
    }
}
