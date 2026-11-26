import AppKit

/// A mouse wheel in the library, eased as Canvas eases it
/// (canvas `CanvasPane.swift`, `wheelPan` and `ease`): each click of the
/// wheel moves a target, and the page glides toward it, fast at first and
/// settling, where the system's own wheel scroll jumps a step at a time.
/// A trackpad's scroll already carries the system's momentum and is left
/// alone.
@MainActor
enum LibraryWheel {
    /// Canvas's ease, a time constant of 60 ms, with less travel: Canvas's
    /// 40 points a line and six lines an event felt quick on a page that
    /// only scrolls, so a line is 27 points and a fast spin counts for
    /// five lines an event at most.
    nonisolated static let pointsPerLine: CGFloat = 27
    nonisolated static let mostLines: CGFloat = 5
    nonisolated static let timeConstant: Double = 0.06

    /// How far the target moves for an event of `lines`.
    nonisolated static func travel(lines: CGFloat) -> CGFloat {
        max(min(lines, mostLines), -mostLines) * pointsPerLine
    }

    /// The share of the remaining way covered in `dt` seconds, the same at
    /// any frame rate.
    nonisolated static func share(after dt: Double) -> CGFloat {
        CGFloat(1 - exp(-max(dt, 0) / timeConstant))
    }

    private static var monitor: Any?
    private static var isLibrary: (NSWindow) -> Bool = { _ in false }
    private static weak var scrollView: NSScrollView?
    private static var target: CGFloat?
    private static var link: CADisplayLink?
    private static var steppedAt: CFTimeInterval = 0
    private static let stepper = Stepper()

    /// Whether a wheel scroll is gliding now: the grid holds its hovers
    /// meanwhile, as it does for a trackpad's scroll.
    static var isEasing: Bool { target != nil }

    static func install(isLibrary: @escaping (NSWindow) -> Bool) {
        self.isLibrary = isLibrary
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Local monitors are called on the main thread.
            nonisolated(unsafe) let event = event
            let taken = MainActor.assumeIsolated { handle(event) }
            return taken ? nil : event
        }
    }

    /// Takes a mouse wheel's vertical step over a library's page; anything
    /// else (a trackpad, a sideways wheel, a wheel with a modifier, another
    /// window) is the system's.
    private static func handle(_ event: NSEvent) -> Bool {
        if event.hasPreciseScrollingDeltas {
            // A trackpad takes over from a glide in progress.
            stop()
            return false
        }
        let lines = event.scrollingDeltaY
        guard lines != 0, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let window = event.window, isLibrary(window), let scrollView = page(in: window, at: event.locationInWindow)
        else { return false }
        let clip = scrollView.contentView
        if self.scrollView !== scrollView { stop() }
        self.scrollView = scrollView
        let base = target ?? clip.bounds.minY
        // A wheel turned away from you scrolls down the page: toward the
        // greater y in a flipped page.
        let wanted = base + travel(lines: lines) * (clip.isFlipped ? -1 : 1)
        var bounds = clip.bounds
        bounds.origin.y = wanted
        target = clip.constrainBoundsRect(bounds).minY
        start(on: scrollView)
        return true
    }

    /// The page under the pointer, or the window's tallest one: the header
    /// and the tab bar lie over the page and are not inside it.
    private static func page(in window: NSWindow, at point: NSPoint) -> NSScrollView? {
        guard let content = window.contentView else { return nil }
        var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        while let current = view {
            if let scroll = current as? NSScrollView, scrolls(scroll) { return scroll }
            view = current.superview
        }
        var found: NSScrollView?
        func search(_ view: NSView) {
            if let scroll = view as? NSScrollView, scrolls(scroll), scroll.frame.height > (found?.frame.height ?? 0) { found = scroll }
            view.subviews.forEach(search)
        }
        search(content)
        return found
    }

    private static func scrolls(_ scroll: NSScrollView) -> Bool {
        (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height
    }

    private static func start(on view: NSScrollView) {
        guard link == nil else { return }
        steppedAt = CACurrentMediaTime()
        let link = view.displayLink(target: stepper, selector: #selector(Stepper.step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    static func stop() {
        link?.invalidate()
        link = nil
        target = nil
    }

    fileprivate static func step() {
        guard let scrollView, let target else { return stop() }
        let now = CACurrentMediaTime()
        let dt = now - steppedAt
        steppedAt = now
        let clip = scrollView.contentView
        let y = clip.bounds.minY + (target - clip.bounds.minY) * share(after: dt)
        let done = abs(target - y) < 0.5
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: done ? target : y))
        scrollView.reflectScrolledClipView(clip)
        if done { stop() }
    }

    private final class Stepper: NSObject {
        @objc func step(_ link: CADisplayLink) {
            MainActor.assumeIsolated { LibraryWheel.step() }
        }
    }
}
