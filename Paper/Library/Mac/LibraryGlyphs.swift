import SwiftUI

// Glyphs the Mac library needs beyond the iPhone's set, drawn the same
// way: a 24 pt grid, a 2 pt line, round caps and joins.

/// Open: an arrow leaving toward the top right.
struct OpenGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(6.5, 17.5))
        path.addLine(to: p(17.5, 6.5))
        path.move(to: p(9, 6.5))
        path.addLine(to: p(17.5, 6.5))
        path.addLine(to: p(17.5, 15))
        return path
    }
}

/// Copy: one rounded sheet in front of another.
struct CopyGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        // The front sheet, lower left.
        path.addRoundedRect(
            in: CGRect(x: rect.minX + 4 * s, y: rect.minY + 9 * s, width: 11 * s, height: 11 * s),
            cornerSize: CGSize(width: 3 * s, height: 3 * s), style: .continuous
        )
        // The back sheet's top and right edges, showing behind it.
        path.move(to: p(9, 6.2))
        path.addQuadCurve(to: p(11.5, 4), control: p(9, 4))
        path.addLine(to: p(17, 4))
        path.addQuadCurve(to: p(20, 7), control: p(20, 4))
        path.addLine(to: p(20, 12.5))
        path.addQuadCurve(to: p(17.8, 15), control: p(20, 15))
        return path
    }
}

/// A glyph with a plus badge in the clear space above its top right
/// corner, as the system's folder-plus has: the badge's ring is cut out
/// of the corner so the two never touch. The iPhone library's New Folder,
/// drawn the same way.
struct PlusBadgedGlyph: View {
    let glyph: AnyShape
    let style: StrokeStyle
    /// Badge centre and the clear ring around it, on the 24 pt grid.
    private static let badge = CGPoint(x: 20.5, y: 3.5)
    private static let clearance: CGFloat = 4.2
    private static let arm: CGFloat = 2.4

    var body: some View {
        glyph
            .stroke(.foreground, style: style)
            .mask {
                Canvas { context, size in
                    let s = size.width / 24
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                    context.blendMode = .destinationOut
                    let r = Self.clearance * s
                    context.fill(Path(ellipseIn: CGRect(
                        x: Self.badge.x * s - r, y: Self.badge.y * s - r, width: r * 2, height: r * 2
                    )), with: .color(.black))
                }
            }
            .overlay {
                Canvas { context, size in
                    let s = size.width / 24
                    let c = CGPoint(x: Self.badge.x * s, y: Self.badge.y * s)
                    var plus = Path()
                    plus.move(to: CGPoint(x: c.x, y: c.y - Self.arm * s))
                    plus.addLine(to: CGPoint(x: c.x, y: c.y + Self.arm * s))
                    plus.move(to: CGPoint(x: c.x - Self.arm * s, y: c.y))
                    plus.addLine(to: CGPoint(x: c.x + Self.arm * s, y: c.y))
                    context.stroke(plus, with: .foreground, style: StrokeStyle(lineWidth: 2 * s, lineCap: .round))
                }
            }
    }
}

/// Reveal: a magnifying glass, for finding the file in Finder.
struct RevealGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.addEllipse(in: CGRect(x: rect.minX + 4.5 * s, y: rect.minY + 4.5 * s, width: 12 * s, height: 12 * s))
        path.move(to: p(15, 15))
        path.addLine(to: p(19.8, 19.8))
        return path
    }
}

/// Hidden items: an eye, an almond with a round pupil.
struct EyeGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(3, 12))
        path.addQuadCurve(to: p(21, 12), control: p(12, 2.5))
        path.addQuadCurve(to: p(3, 12), control: p(12, 21.5))
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: rect.minX + 9.25 * s, y: rect.minY + 9.25 * s, width: 5.5 * s, height: 5.5 * s))
        return path
    }
}
