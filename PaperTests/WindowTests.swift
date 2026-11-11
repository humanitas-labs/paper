import AppKit
import Testing
@testable import Paper

@MainActor
struct WindowCentringTests {
    /// The welcome window sits in the exact middle of the screen's visible
    /// area, not the upward-shifted spot `center()` picks, and never
    /// larger than that area.
    @Test
    func centerExactlyPutsTheWindowInTheMiddleOfTheVisibleArea() throws {
        let screen = try #require(NSScreen.main)
        let visible = screen.visibleFrame
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: visible.height + 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.centerExactly()
        let frame = window.frame
        #expect(frame.height <= visible.height, "shrunk to the visible area")
        #expect(abs(frame.midX - visible.midX) < 1, "middle x \(frame.midX) vs \(visible.midX)")
        #expect(abs(frame.midY - visible.midY) < 1, "middle y \(frame.midY) vs \(visible.midY)")
    }
}

struct NewWindowPlacementTests {
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
    let size = CGSize(width: 1400, height: 840)

    /// With no document window open, a new one sits in the middle of the
    /// visible area.
    @Test
    func theFirstWindowIsCentred() {
        let frame = NewWindowPlacement.frame(size: size, cascadingFrom: nil, in: visible)
        #expect(frame == CGRect(x: 56, y: 54, width: 1400, height: 840))
    }

    /// A new window cascades one step down and right of the front window,
    /// not of the oldest one, so it never lands exactly on another.
    @Test
    func aNewWindowCascadesFromTheFrontWindow() {
        let front = CGRect(x: 56, y: 54, width: 1400, height: 840)
        let frame = NewWindowPlacement.frame(size: size, cascadingFrom: front, in: visible)
        #expect(frame == CGRect(x: 85, y: 25, width: 1400, height: 840))
    }

    /// A cascade that would leave the visible area, under the menu bar or
    /// past an edge, centres the window instead.
    @Test
    func aCascadeOffTheScreenCentresTheWindow() {
        let centred = CGRect(x: 56, y: 54, width: 1400, height: 840)
        for front in [CGRect(x: 85, y: 25, width: 1400, height: 840), CGRect(x: -40, y: 140, width: 1400, height: 840)] {
            #expect(NewWindowPlacement.frame(size: size, cascadingFrom: front, in: visible) == centred)
        }
    }

    /// The cascade follows a smaller front window and keeps the new
    /// window's own size; a window larger than the screen shrinks to it.
    @Test
    func theNewWindowKeepsItsSizeAndFitsTheScreen() {
        let small = CGSize(width: 800, height: 500)
        let front = CGRect(x: 300, y: 300, width: 800, height: 500)
        #expect(NewWindowPlacement.frame(size: small, cascadingFrom: front, in: visible) == CGRect(x: 329, y: 271, width: 800, height: 500))
        let huge = NewWindowPlacement.frame(size: CGSize(width: 3000, height: 2000), cascadingFrom: nil, in: visible)
        #expect(huge == visible)
    }
}
