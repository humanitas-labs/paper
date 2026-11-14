import AppKit

/// What the outline column shows for one window, and the bridge back into
/// its editor: the document's headings, the section in view, where the
/// page sits, and the jump a click makes. Each document window owns one;
/// it holds the editor's views weakly and does nothing while inactive.
@MainActor
final class OutlineModel: ObservableObject {
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
    /// Read in `deinit`, which is not on the main actor; only touched there
    /// and on the main actor otherwise.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// How long typing must pause before the headings are read again.
    static let debounce: Duration = .milliseconds(250)

    /// The distance below the top of the page's first line at which a
    /// heading counts as reached: a jump lands it exactly there.
    static let readingTolerance: CGFloat = 8

    var isActive: Bool { active }

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
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The setting, as this window follows it. Off cancels any pending
    /// scan and forgets the headings.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
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
        guard !headings.isEmpty,
              let textView, let scrollView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            if current != nil { current = nil }
            return
        }
        let clip = scrollView.contentView.bounds
        let y = clip.minY + textView.textContainerInset.height + Self.readingTolerance - textView.textContainerOrigin.y
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

        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(NSMaxRange(target.range), length)))
        let glyph = layoutManager.glyphIndexForCharacter(at: min(target.range.location, max(0, length - 1)))
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let clip = scrollView.contentView
        let y = line.minY + textView.textContainerOrigin.y - textView.textContainerInset.height
        let origin = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin

        jumping = true
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        jumping = false
        current = index

        textView.setSelectedRange(NSRange(location: min(target.contentRange.location, length), length: 0))
        textView.window?.makeFirstResponder(textView)
    }
}
