import AppKit
import SwiftUI

/// The library's pointer: a short, tilted arrowhead with rounded corners,
/// black inside a white rim over a soft shadow, as Spatial's pointer reads.
/// Drawn here on a 24 pt grid; nothing is taken from another app.
@MainActor
enum LibraryPointer {
    static let cursor: NSCursor = {
        let size = NSSize(width: 24, height: 25)
        let image = NSImage(size: size, flipped: true) { _ in
            let head = arrowhead()
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 2.5
            // A shadow's offset is in base space, up positive, whatever
            // the image's flip; it falls a point below.
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            NSColor.white.setFill()
            head.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.setStroke()
            head.lineWidth = 3.4
            head.stroke()
            // The black is drawn a hair larger with round joins, which
            // rounds its corners as the rim's are rounded.
            let ink = NSColor(white: 0.08, alpha: 1)
            ink.setFill()
            ink.setStroke()
            head.fill()
            head.lineWidth = 0.9
            head.stroke()
            return true
        }
        // The hot spot is the tip, measured from the top left.
        return NSCursor(image: image, hotSpot: NSPoint(x: 5, y: 4.5))
    }()

    /// Tip at the top left; one wing to the right, one below, and a
    /// shallow notch between them. Every corner is rounded.
    private static func arrowhead() -> NSBezierPath {
        let tip = NSPoint(x: 5, y: 4.5)
        let right = NSPoint(x: 18.8, y: 9.6)
        let notch = NSPoint(x: 12, y: 12.3)
        let bottom = NSPoint(x: 10.8, y: 18.6)
        let path = NSBezierPath()
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.move(to: tip)
        path.line(to: right)
        path.line(to: notch)
        path.line(to: bottom)
        path.close()
        return path
    }
}

/// Lays the library's pointer over the view's whole area.
struct LibraryPointerArea: NSViewRepresentable {
    func makeNSView(context: Context) -> PointerView { PointerView() }
    func updateNSView(_ view: PointerView, context: Context) {}

    final class PointerView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: LibraryPointer.cursor)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
