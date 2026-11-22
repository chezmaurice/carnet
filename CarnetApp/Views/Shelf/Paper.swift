import SwiftUI

// The two papers of an entry, told apart without colour: texture and voice.
// *Mine* is the palette's paper sown with dots of ink, and the same dots
// return wherever the member writes for themself. *Shared* is smooth paper.

/// Which face of the sheet is up.
enum Face { case mine, shared }

/// What the back of the sheet holds, shown on the folded corner.
enum BackPaper { case mine, shared, blank }

/// A field of ink dots on a 7pt grid, drawn over whatever is beneath.
struct Dots: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 7
            var path = Path()
            var y: CGFloat = step / 2
            while y < size.height {
                var x: CGFloat = step / 2
                while x < size.width {
                    path.addEllipse(in: CGRect(x: x - 0.55, y: y - 0.55, width: 1.1, height: 1.1))
                    x += step
                }
                y += step
            }
            ctx.fill(path, with: .color(CarnetTheme.ruleHard))
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// The paper of one face behind a view, in a shape.
    func paper<S: Shape>(_ face: Face, in shape: S) -> some View {
        background {
            ZStack {
                shape.fill(face == .mine ? CarnetTheme.bg : CarnetTheme.surface)
                if face == .mine { Dots().clipShape(shape) }
            }
        }
    }
}

/// A sheet whose bottom-trailing corner is folded over: a rounded rectangle
/// with that corner cut off on the diagonal.
struct SheetShape: InsettableShape {
    var radius: CGFloat = 14
    var fold: CGFloat = 46
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> SheetShape {
        var s = self
        s.inset += amount
        return s
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let rad = max(0, radius - inset)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + rad, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - rad, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + rad), radius: rad)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - fold))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - rad), radius: rad)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + rad, y: r.minY), radius: rad)
        p.closeSubpath()
        return p
    }
}

/// The folded corner itself: a triangle in the paper of the other face.
struct FoldedCorner: View {
    let back: BackPaper
    var size: CGFloat = 46

    private var triangle: Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: size, y: 0))
        p.addLine(to: CGPoint(x: 0, y: size))
        p.closeSubpath()
        return p
    }

    var body: some View {
        ZStack {
            switch back {
            case .mine:
                triangle.fill(CarnetTheme.bg)
                Dots().clipShape(triangle)
            case .shared:
                triangle.fill(CarnetTheme.surface)
            case .blank:
                triangle.fill(CarnetTheme.bg)
            }
            triangle.stroke(CarnetTheme.ruleHard,
                            style: StrokeStyle(lineWidth: 1, lineJoin: .round, dash: back == .blank ? [3, 3] : []))
        }
        .frame(width: size, height: size)
    }
}
