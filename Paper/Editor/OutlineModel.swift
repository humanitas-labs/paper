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
    /// Where the page's first line sits below the window's top (the text
    /// view's top inset), so the column's first entry lines up with it.
    /// Follows zoom, the title band, and full screen.
    @Published private(set) var top: CGFloat = 132
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
            MainActor.assumeIsolated { self?.scheduleScan() }
        })
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCurrent() }
        })
        // Width, zoom, measure, the title band, and full screen all land
        // in the text view's frame and inset, which it reports here.
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
        if fresh != headings { pinned = nil }
        if fresh != headings { headings = fresh }
        updateCurrent()
    }

    func updateGeometry() {
        guard active, let textView, let scrollView, let container = textView.textContainer else { return }
        let top = textView.textContainerInset.height
        let textRight = textView.convert(
            NSPoint(x: textView.textContainerOrigin.x + container.size.width, y: 0), to: scrollView
        ).x
        let room = max(0, scrollView.bounds.width - textRight)
        if abs(top - self.top) >= 0.5 { self.top = top }
        if abs(room - self.room) >= 0.5 { self.room = room }
    }

    /// The section whose heading last crossed the reading line, the place
    /// a jump lands a heading.
    func updateCurrent() {
        guard active, !jumping else { return }
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
    /// and gives the text view the keys.
    func jump(to heading: OutlineHeading) {
        if scanPending { scanNow() }
        guard let index = headings.firstIndex(where: { $0.id == heading.id }),
              let textView, let scrollView,
              let layoutManager = textView.layoutManager else { return }
        let target = headings[index]
        let length = (textView.string as NSString).length
        guard target.range.location < length || length == 0 else { return }

        // The caret first: moving it reveals this heading's syntax and
        // conceals the paragraph it leaves, and either can change line
        // heights above the target (a long heading wraps once its marks
        // show). Measured before, the landing point is off by that much.
        textView.setSelectedRange(NSRange(location: min(target.contentRange.location, length), length: 0))

        // Lay out through the heading, and a viewport past it so the
        // scroll is not clamped short of a frame still growing behind
        // the layout.
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

        jumping = true
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        jumping = false
        current = index
        pinned = (index, clip.bounds.minY)
        textView.window?.makeFirstResponder(textView)
    }
}
