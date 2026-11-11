import AppKit

/// Where a new document window opens. SwiftUI's own placement cascades every
/// new window from the oldest window still open, not the front one: the
/// third window lands exactly on the second, and once the oldest closes the
/// next starts over near the screen's top-left corner, against the menu bar.
/// Paper places it instead: one step down and right of the front document
/// window, or in the middle of the screen when there is none or the step
/// would leave the screen. (SwiftUI's `defaultWindowPlacement` is consulted
/// only for the first window; its cascade wins for the rest.)
enum NewWindowPlacement {
    /// The cascade step AppKit and SwiftUI use.
    static let step: CGFloat = 29

    /// The frame, in screen coordinates, for a new window of `size`:
    /// cascaded from `front` when that lies wholly inside `visible`, and
    /// otherwise centred in `visible` on whole points; never larger than
    /// `visible`.
    static func frame(size: CGSize, cascadingFrom front: CGRect?, in visible: CGRect) -> CGRect {
        let size = CGSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
        if let front {
            let cascaded = CGRect(x: front.minX + step, y: front.maxY - step - size.height, width: size.width, height: size.height)
            if visible.contains(cascaded) { return cascaded }
        }
        return CGRect(
            x: (visible.midX - size.width / 2).rounded(.down), y: (visible.midY - size.height / 2).rounded(.down),
            width: size.width, height: size.height
        )
    }

    /// Off until the app has finished launching, so windows the system
    /// restores at launch keep the frames it saved for them.
    @MainActor static var isEnabled = false

    /// The document windows, held weakly. SwiftUI's documents do not list
    /// their windows in `windowControllers`, so Paper keeps its own record.
    @MainActor static let documentWindows = NSHashTable<NSWindow>.weakObjects()
}

extension NSWindow {
    /// Moves a document window that has just opened to its place and
    /// records it as a document window. A window opened as a tab or in full
    /// screen stays where the system put it.
    func placeAsNewDocumentWindow() {
        let windows = NewWindowPlacement.documentWindows
        windows.add(self)
        guard NewWindowPlacement.isEnabled, !styleMask.contains(.fullScreen),
              (tabbedWindows?.count ?? 0) <= 1 else { return }
        let front = NSApp.orderedWindows.first { other in
            other !== self && windows.contains(other) && other.isVisible && !other.isMiniaturized
                && !other.styleMask.contains(.fullScreen)
        }
        guard let visible = (front?.screen ?? screen ?? NSScreen.main)?.visibleFrame else { return }
        let placed = NewWindowPlacement.frame(size: frame.size, cascadingFrom: front?.frame, in: visible)
        setFrame(placed, display: false)
    }
}
