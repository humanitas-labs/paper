import AppKit

/// What the outline column shows for one window, and the bridge back into
/// its editor: whether the outline is shown, the document's headings, the
/// section in view, where the page sits, and the jump a click makes. Each
/// document window owns one. Whether it shows is this window's own state,
/// seeded from the `outline` setting when the window opens and flipped by
/// ⌥Tab; nothing persists it. It holds the editor's views weakly and does
/// nothing while hidden.
@MainActor
final class OutlineModel: ObservableObject {
    /// Whether this window shows the outline.
    @Published private(set) var isVisible = false
    @Published private(set) var headings: [OutlineHeading] = []
    /// Index into `headings` of the section in view; nil above the first.
    @Published private(set) var current: Int?
    /// The baseline of the page's first line, below the editor's top (in
    /// the scroll view's coordinates, top down) with the document scrolled
    /// to its top; the column's first entry sits on it. Measured from
    /// layout, not the inset: a heading's font and spacing put its
    /// baseline well below the top of its line. Follows zoom, the theme
    /// and fonts, the title band, full screen, and edits to that line.
    @Published private(set) var firstBaseline: CGFloat = 160
    /// Room between the right edge of the text and the right edge of the
    /// window; the column's width follows it, or it hides.
    @Published private(set) var room: CGFloat = 0

    private weak var textView: PaperTextView?
    private weak var scrollView: NSScrollView?
    private var active = false
    private var scan: Task<Void, Never>?
    private var generation = 0
    private var scanPending = false
    private var jumping = false
    /// The eased scroll a click started, until it lands or is cut short:
    /// the heading it is going to, and a serial so a landing that belongs
    /// to an earlier click is ignored.
    private var flight: Flight?
    private var flights = 0
    private var ticker: FrameTicker?

    private struct Flight {
        let index: Int
        let serial: Int
        /// The clip's distance below the text view's top, at the start
        /// and at the end.
        let from: CGFloat
        let to: CGFloat
        let start: CFTimeInterval
        let duration: TimeInterval
    }
    /// The heading a jump marked and the clip origin it left. Near the
    /// end of a document a heading cannot reach the reading line, so the
    /// mark stays on the clicked heading until the view scrolls away.
    private var pinned: (index: Int, origin: CGFloat)?
    /// Read in `deinit`, which is not on the main actor; only touched there
    /// and on the main actor otherwise.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// How long typing must pause before the headings are read again.
    static let debounce: Duration = .milliseconds(250)

    /// The distance below the top of the page's first line at which a
    /// heading counts as reached: a jump lands it exactly there.
    static let readingTolerance: CGFloat = 8

    /// How far the clip may settle after a jump (AppKit re-constrains it
    /// at the document's end on the next tile) before the mark follows
    /// the scroll again.
    static let pinTolerance: CGFloat = 8

    /// The eased scroll to a clicked heading: a quarter of a second for
    /// a short hop, a little longer for a long one, never more than
    /// `maximumScrollDuration`.
    nonisolated static let scrollDurations: ClosedRange<TimeInterval> = 0.25...0.35
    nonisolated static let maximumScrollDuration: TimeInterval = 0.4

    /// How long the scroll over `distance` takes in a viewport `viewport`
    /// tall: the short duration within one viewport, the long one from
    /// five viewports on.
    nonisolated static func scrollDuration(distance: CGFloat, viewport: CGFloat) -> TimeInterval {
        let viewports = viewport > 0 ? Double(abs(distance) / viewport) : 0
        let fraction = min(max((viewports - 1) / 4, 0), 1)
        let duration = scrollDurations.lowerBound + (scrollDurations.upperBound - scrollDurations.lowerBound) * fraction
        return min(duration, maximumScrollDuration)
    }

    /// Whether a click jumps instead of easing: the system's Reduce
    /// Motion setting. Replaced in tests.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// True while an eased scroll to a clicked heading is under way.
    var isScrolling: Bool { flight != nil }

    var isActive: Bool { active }

    /// A window's outline, shown or not as `visible` says; for a new
    /// window, the configured default. It scans once attached.
    init(visible: Bool = false) {
        active = visible
        isVisible = visible
    }

    /// The model a newly opened window starts with: shown when the
    /// configuration says new documents open with the outline.
    static func forNewWindow(_ configuration: Configuration) -> OutlineModel {
        OutlineModel(visible: configuration.outline)
    }

    /// ⌥Tab and View ▸ Show/Hide Outline: this window only.
    func toggle() {
        setActive(!active)
    }

    func attach(textView: PaperTextView, scrollView: NSScrollView) {
        detach()
        self.textView = textView
        self.scrollView = scrollView
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSText.didChangeNotification, object: textView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleScan()
                // The edit may have restyled the first line (a `#` typed
                // before it); the styler runs in the delegate's turn, so
                // measure once this notification has gone round.
                DispatchQueue.main.async { self?.updateGeometry() }
            }
        })
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCurrent() }
        })
        // A scroll of the reader's own takes the page back from an eased
        // jump. A trackpad or a dragged knob brackets its scrolling; a
        // wheel only reports each step.
        for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification] {
            observers.append(center.addObserver(forName: name, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.userDidScroll() }
            })
        }
        // Width, zoom, measure, fonts, the title band, and full screen all
        // land in the text view's frame, inset, or styling, which it
        // reports here.
        // ⌥Tab reaching the text view toggles this window's outline.
        textView.toggleOutline = { [weak self] in self?.toggle() }
        textView.geometryDidChange = { [weak self] in
            self?.updateGeometry()
            self?.updateCurrent()
        }
        if active {
            updateGeometry()
            scanNow()
        }
    }

    private func detach() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        textView?.geometryDidChange = nil
        textView?.toggleOutline = nil
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Calls `tick` once a frame until stopped: on the display's refresh
    /// while the window is on screen, on a timer where no display drives
    /// it (a window not yet shown, the tests). One more call comes at the
    /// deadline whatever happens, so a display link paused with its
    /// window still lets the scroll land.
    @MainActor
    private final class FrameTicker: NSObject {
        private var link: CADisplayLink?
        private var timers: [Timer] = []
        private let tick: @MainActor () -> Void

        init(view: NSView, deadline: TimeInterval, tick: @escaping @MainActor () -> Void) {
            self.tick = tick
            super.init()
            if let window = view.window, window.isVisible, window.occlusionState.contains(.visible) {
                let link = view.displayLink(target: self, selector: #selector(step))
                link.add(to: .main, forMode: .common)
                self.link = link
            } else {
                schedule(Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                })
            }
            schedule(Timer(timeInterval: deadline + 0.05, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            })
        }

        private func schedule(_ timer: Timer) {
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
        }

        @objc private func step(_ link: CADisplayLink) { tick() }

        func stop() {
            link?.invalidate()
            link = nil
            for timer in timers { timer.invalidate() }
            timers = []
        }
    }

    /// Shows or hides this window's outline. Hidden cancels any pending
    /// scan and forgets the headings.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        isVisible = on
        if on {
            updateGeometry()
            scanNow()
        } else {
            cancelFlight()
            scan?.cancel()
            generation += 1
            scanPending = false
            headings = []
            current = nil
        }
    }

    /// The editor replaced its text from outside (a reload from disk).
    func textWasReplaced() {
        scheduleScan()
    }

    /// Reads the headings again once typing pauses, off the main actor;
    /// a newer edit cancels an older scan.
    private func scheduleScan() {
        guard active else { return }
        scanPending = true
        scan?.cancel()
        generation += 1
        let generation = generation
        scan = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let text = self?.textView?.string else { return }
            let headings = await Task.detached(priority: .userInitiated) { Outline.headings(in: text) }.value
            guard let self, !Task.isCancelled, self.generation == generation, self.active else { return }
            self.publish(headings)
        }
    }

    /// Reads the headings now, on the main actor: on activation, before a
    /// jump while a scan is pending, and in tests.
    func scanNow() {
        guard active, let textView else { return }
        scan?.cancel()
        generation += 1
        publish(Outline.headings(in: textView.string))
    }

    private func publish(_ fresh: [OutlineHeading]) {
        scanPending = false
        if fresh != headings {
            // The index a pin or an eased jump holds is stale: the page
            // stays where it is and the mark follows it.
            pinned = nil
            cancelFlight()
            headings = fresh
        }
        // An edit to the first line can change its font and so its
        // baseline.
        updateGeometry()
        updateCurrent()
    }

    func updateGeometry() {
        guard active, let textView, let scrollView, let container = textView.textContainer else { return }
        let firstBaseline = Self.firstBaseline(of: textView, in: scrollView)
        let textRight = textView.convert(
            NSPoint(x: textView.textContainerOrigin.x + container.size.width, y: 0), to: scrollView
        ).x
        let room = max(0, scrollView.bounds.width - textRight)
        if abs(firstBaseline - self.firstBaseline) >= 0.5 { self.firstBaseline = firstBaseline }
        if abs(room - self.room) >= 0.5 { self.room = room }
    }

    /// The first line's baseline in the scroll view's coordinates, top
    /// down, as it sits with the document at its top: the first glyph's
    /// line fragment plus the typesetter's baseline in it, moved into the
    /// scroll view through the same conversion the jump uses (the text
    /// view's frame need not start at the clip's origin), with the
    /// current scroll taken back out.
    static func firstBaseline(of textView: PaperTextView, in scrollView: NSScrollView) -> CGFloat {
        var baseline = textView.textContainerOrigin.y
        if let layoutManager = textView.layoutManager, layoutManager.numberOfGlyphs > 0 {
            layoutManager.ensureLayout(forGlyphRange: NSRange(location: 0, length: 1))
            baseline += layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY
                + layoutManager.location(forGlyphAt: 0).y
        } else {
            baseline += (textView.font ?? Appearance.bodyFont()).ascender
        }
        let point = textView.convert(NSPoint(x: 0, y: baseline), to: scrollView)
        let fromTop = scrollView.isFlipped ? point.y : scrollView.bounds.height - point.y
        // How far the clip has scrolled past the text view's top, in the
        // clip's coordinates; unlike `visibleRect` it is not clipped
        // while the page rubber-bands.
        let scrolled = scrollView.contentView.bounds.minY - textView.frame.minY
        return fromTop + scrolled
    }

    /// The section whose heading last crossed the reading line, the place
    /// a jump lands a heading.
    func updateCurrent() {
        // An eased jump holds the mark on the clicked heading while the
        // headings between pass the reading line.
        guard active, !jumping, flight == nil else { return }
        if let pinned, let clip = scrollView?.contentView,
           abs(clip.bounds.minY - pinned.origin) < Self.pinTolerance, headings.indices.contains(pinned.index) {
            if current != pinned.index { current = pinned.index }
            return
        }
        pinned = nil
        guard !headings.isEmpty,
              let textView, let scrollView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            if current != nil { current = nil }
            return
        }
        // The viewport's top in the text view's own coordinates; the
        // clip view's bounds are in its coordinates, offset by wherever
        // the text view's frame sits.
        let top = textView.visibleRect.minY
        let y = top + textView.textContainerInset.height + Self.readingTolerance - textView.textContainerOrigin.y
        let index = layoutManager.characterIndex(
            for: NSPoint(x: 0, y: max(0, y)), in: container, fractionOfDistanceBetweenInsertionPoints: nil
        )
        // A point below the last line maps to the last character; one
        // above the first heading's line maps before it.
        let section = Outline.sectionIndex(containing: index, in: headings)
        if section != current { current = section }
    }

    /// Scrolls the heading's line to where the page's first line sits at
    /// the top of the document, puts the caret at the start of its text,
    /// and gives the text view the keys. In a window the scroll eases to
    /// its end; under Reduce Motion, or with `animated` false, it jumps.
    /// The mark goes to the heading at once and stays there on the way.
    func jump(to heading: OutlineHeading, animated: Bool = true) {
        if scanPending { scanNow() }
        guard let index = headings.firstIndex(where: { $0.id == heading.id }),
              let textView, let scrollView,
              let layoutManager = textView.layoutManager else { return }
        let target = headings[index]
        let length = (textView.string as NSString).length
        guard target.range.location < length || length == 0 else { return }

        // A second click takes over from wherever the first has got to.
        cancelFlight()

        // The caret first: moving it reveals this heading's syntax and
        // conceals the paragraph it leaves, and either can change line
        // heights above the target (a long heading wraps once its marks
        // show). Measured before, the landing point is off by that much.
        textView.setSelectedRange(NSRange(location: min(target.contentRange.location, length), length: 0))

        // Lay out through the heading, and a viewport past it so the
        // scroll is not clamped short of a frame still growing behind
        // the layout. All of it before the scroll starts: an eased scroll
        // must not find its end point moving under it.
        let clip = scrollView.contentView
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(NSMaxRange(target.range), length)))
        let glyph = layoutManager.glyphIndexForCharacter(at: min(target.range.location, max(0, length - 1)))
        let laidOut = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        if let container = textView.textContainer {
            layoutManager.ensureLayout(
                forBoundingRect: NSRect(x: 0, y: laidOut.minY, width: container.size.width, height: clip.bounds.height * 2),
                in: container
            )
            // The frame follows layout later, on its own schedule; sized
            // now, the clamp below sees the document's real end.
            textView.sizeToFit()
        }
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        // The landing point is in the text view's coordinates; the clip
        // view scrolls in its own, and the text view's frame need not
        // start at its origin (it sits at a large negative y once the
        // document has grown from an empty frame), so convert.
        let landing = textView.convert(
            NSPoint(x: 0, y: line.minY + textView.textContainerOrigin.y - textView.textContainerInset.height),
            to: clip
        )
        let origin = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.minX, y: landing.y), size: clip.bounds.size)).origin

        current = index
        pinned = nil
        textView.window?.makeFirstResponder(textView)

        let distance = abs(origin.y - clip.bounds.minY)
        guard animated, textView.window != nil, distance >= 1, !reducesMotion() else {
            land(at: origin.y - textView.frame.minY, index: index)
            return
        }
        // Both ends as distances below the text view's top, which hold if
        // its frame moves in the clip while the scroll runs.
        flights += 1
        let flight = Flight(
            index: index,
            serial: flights,
            from: clip.bounds.minY - textView.frame.minY,
            to: origin.y - textView.frame.minY,
            start: CACurrentMediaTime(),
            duration: Self.scrollDuration(distance: distance, viewport: clip.bounds.height)
        )
        self.flight = flight
        ticker = FrameTicker(view: textView, deadline: flight.duration) { [weak self] in
            self?.advance(flight.serial)
        }
    }

    /// One frame of the eased scroll: where the clock says the page is by
    /// now, and the landing once the time is up.
    private func advance(_ serial: Int) {
        guard let flight, flight.serial == serial, let textView, let scrollView else { return }
        let progress = (CACurrentMediaTime() - flight.start) / flight.duration
        guard progress < 1 else {
            cancelFlight()
            land(at: flight.to, index: flight.index)
            return
        }
        let clip = scrollView.contentView
        let offset = flight.from + (flight.to - flight.from) * Self.eased(progress)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: textView.frame.minY + offset))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Ease in and out, a cubic each way: no overshoot, no bounce.
    nonisolated static func eased(_ progress: Double) -> Double {
        let t = min(max(progress, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// Puts the clip `offset` below the text view's top, as far as the
    /// document allows, and pins the mark there.
    private func land(at offset: CGFloat, index: Int) {
        guard let textView, let scrollView else { return }
        let clip = scrollView.contentView
        let origin = NSPoint(x: clip.bounds.minX, y: textView.frame.minY + offset)
        jumping = true
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
        jumping = false
        current = index
        pinned = (index, clip.bounds.minY)
    }

    /// Lets go of an eased scroll, leaving the page where it has got to.
    private func cancelFlight() {
        flight = nil
        ticker?.stop()
        ticker = nil
    }

    /// The reader scrolled: an eased jump lets go, and the mark follows
    /// the page again.
    private func userDidScroll() {
        guard flight != nil else { return }
        cancelFlight()
        pinned = nil
        updateCurrent()
    }
}
