import AppKit
import QuartzCore

/// Opening a note from its card: the card's page lifts off the grid and
/// grows into the note's window. The real window opens unseen; a
/// borderless stand-in showing the card's miniature travels from the card
/// to the window's frame, and the window takes its place as it arrives.
@MainActor
enum NoteOpenAnimation {
    static let duration: TimeInterval = 0.42
    static let handoff: TimeInterval = 0.14

    /// - Parameters:
    ///   - card: the card's frame on screen.
    ///   - miniature: the card's page, if it has been drawn.
    static func open(_ url: URL, from card: NSRect?, miniature: NSImage?, library: NSWindow?) {
        let already = NSDocumentController.shared.document(for: url) != nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let card, !already, !reduceMotion else {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            return
        }
        let stand = standIn(at: card, miniature: miniature, appearance: library?.effectiveAppearance)
        stand.orderFront(nil)

        // The note's window, caught as it first becomes main, before it
        // has drawn: it stays clear until the stand-in reaches it.
        var observer: NSObjectProtocol?
        var finished = false
        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard !finished, window !== stand, window !== library, !(window is NSPanel) else { return }
                finished = true
                stopObserving()
                window.alphaValue = 0
                // A turn of the run loop, so Paper has placed the window.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    grow(stand, into: window)
                }
            }
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            MainActor.assumeIsolated {
                guard error != nil, !finished else { return }
                finished = true
                stopObserving()
                stand.orderOut(nil)
            }
        }
        // A window that never comes must not leave the stand-in up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard !finished else { return }
            finished = true
            stopObserving()
            stand.orderOut(nil)
        }
    }

    private static func grow(_ stand: NSWindow, into window: NSWindow) {
        let target = window.frame
        stand.order(.above, relativeTo: window.windowNumber)
        if let layer = stand.contentView?.layer {
            let corners = CABasicAnimation(keyPath: "cornerRadius")
            corners.fromValue = layer.cornerRadius
            corners.toValue = Appearance.windowCornerRadius
            corners.duration = duration
            corners.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
            layer.add(corners, forKey: "corners")
            layer.cornerRadius = Appearance.windowCornerRadius
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
            context.allowsImplicitAnimation = true
            stand.animator().setFrame(target, display: true)
        } completionHandler: {
            MainActor.assumeIsolated {
                // The real window fades up under the stand-in, which then
                // fades away: the page seems to settle into its window.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = handoff
                    window.animator().alphaValue = 1
                    stand.animator().alphaValue = 0
                } completionHandler: {
                    MainActor.assumeIsolated { stand.orderOut(nil) }
                }
            }
        }
    }

    /// A borderless window over the card: the page's ground with the
    /// miniature held to its top, scaled to fit as the window grows, so
    /// the text ends up a column in the middle, as it sits in the note.
    private static func standIn(at frame: NSRect, miniature: NSImage?, appearance: NSAppearance?) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.appearance = appearance
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        // The card's own corner: 24 pt on a card 235 pt wide.
        content.layer?.cornerRadius = frame.width * 24.0 / 235.0
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        (appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            content.layer?.backgroundColor = Appearance.canvas.cgColor
        }
        if let miniature {
            let image = NSImageView(frame: content.bounds)
            image.image = miniature
            image.imageScaling = .scaleProportionallyUpOrDown
            image.imageAlignment = .alignTop
            image.autoresizingMask = [.width, .height]
            content.addSubview(image)
        }
        window.contentView = content
        return window
    }
}
