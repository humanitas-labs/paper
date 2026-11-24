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

/// New folder: the iPhone's folder with a plus in its body.
struct NewFolderGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = FolderGlyph().path(in: rect)
        path.move(to: p(12, 10.6))
        path.addLine(to: p(12, 16.2))
        path.move(to: p(9.2, 13.4))
        path.addLine(to: p(14.8, 13.4))
        return path
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
