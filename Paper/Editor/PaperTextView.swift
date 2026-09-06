import AppKit

final class PaperTextView: NSTextView {
    let syntaxStyler = MarkdownSyntaxStyler()

    /// The file this view edits, set by the editor and kept current across
    /// Save As; relative paths in links and images resolve against its
    /// folder. Nil for a document not yet saved.
    /// The image a single click marked, drawn under a wash until the next
    /// click or keystroke; see `ImagePreview.swift`. The wash fades, so
    /// the band it covers and its current strength are kept apart.
    var selectedImage: URL? {
        didSet { if selectedImage != oldValue { animateImageWash() } }
    }
    var imageWash: (url: URL, alpha: CGFloat)?
    var imageWashTimer: Timer?

    var documentURL: URL? {
        didSet {
            guard documentURL != oldValue else { return }
            syntaxStyler.apply(to: self)
        }
    }

    // MARK: - File ▸ Copy Path

    /// ⌥⌘C: the file's absolute path as plain text. The window hides its
    /// title bar, so this stands in for the proxy icon.
    @objc func copyPath(_ sender: Any?) {
        guard let documentURL else { return }
        DocumentPath.copy(documentURL)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copyPath(_:)) { return documentURL != nil }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - File ▸ Export as PDF…

    /// ⇧⌘E: the buffer as it reads here, on Letter or A4 pages; see
    /// `PDFExporter`. Unsaved edits export; the file on disk is not touched.
    @objc func exportPDF(_ sender: Any?) {
        PDFExporter.present(for: self)
    }

    /// ⌘P: the print panel over the pages the export makes, not AppKit's
    /// rendering of the live view; its PDF menu saves the same pages.
    @objc func printPages(_ sender: Any?) {
        PDFExporter.print(self)
    }

    override func printView(_ sender: Any?) {
        printPages(sender)
    }

    /// The PDF's title and the print job's name.
    override var printJobTitle: String {
        documentURL?.deletingPathExtension().lastPathComponent ?? Self.placeholderTitle
    }

    init() {
        let storage = NSTextStorage()
        let layoutManager = PaperLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)

        storage.delegate = self
        configure()
        observeSettings()
        observeImageLoads()
        observeFrameChanges()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Every selection setter funnels through this primitive, so it is the one
    /// place that decides which paragraphs show their Markdown punctuation:
    /// those the selection touches. The reveal waits for the selection to
    /// settle: AppKit passes `stillSelecting` while the mouse is down, and a
    /// paragraph revealed under a pressed pointer shifts its glyphs so the
    /// tracking loop reads the shift as a drag and selects a character or
    /// two (#42). While an input method holds marked text the revealed range
    /// is frozen, as restyling already is.
    /// A list item's prefix is one unit for the caret (#53, #50), so any
    /// range reaching into one is snapped out of it here, where every key,
    /// click, drag, and undo lands.
    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        var ranges = ranges
        if !hasMarkedText(), let storage = textStorage {
            let text = storage.string as NSString
            let previous = selectedRanges.count == 1 ? selectedRanges[0].rangeValue : nil
            ranges = ranges.map { value in
                let range = value.rangeValue
                guard NSMaxRange(range) <= text.length else { return value }
                var snapped = ListPrefix.snapped(range, previous: previous, in: text)
                snapped = ContinuationIndent.snapped(snapped, previous: previous, in: storage)
                return snapped == range ? value : NSValue(range: snapped)
            }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !stillSelecting, !hasMarkedText() else { return }
        revealSelectedParagraphs()
    }

    /// Backspace at the start of an item's text removes the whole prefix,
    /// leaving a plain line; Delete right before the prefix does nothing.
    /// The prefix never holds the caret, so neither can eat into it.
    /// Backspace at the text's start of a hard-wrapped item's continuation
    /// removes the newline and the indent together, joining the lines;
    /// Delete right before that newline does the same.
    override func deleteBackward(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), let storage = textStorage,
              let unit = ListPrefix.backspaceRange(in: string as NSString, selection: selectedRange())
                ?? ContinuationIndent.backspaceRange(in: storage, selection: selectedRange())
        else { return super.deleteBackward(sender) }
        remove(unit)
    }

    override func deleteForward(_ sender: Any?) {
        guard !ListPrefix.deleteForwardIsBlocked(in: string as NSString, selection: selectedRange()) else { return }
        if isEditable, !hasMarkedText(), let storage = textStorage,
           let unit = ContinuationIndent.deleteForwardRange(in: storage, selection: selectedRange()) {
            return remove(unit)
        }
        super.deleteForward(sender)
    }

    /// Removes `unit` as one undoable step and leaves the caret at its start.
    private func remove(_ unit: NSRange) {
        breakUndoCoalescing()
        guard shouldChangeText(in: unit, replacementString: "") else { return }
        textStorage?.replaceCharacters(in: unit, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: unit.location, length: 0))
        breakUndoCoalescing()
    }

    /// The union of the paragraphs touched by the selection. Disjoint
    /// selections reveal everything between them as well, which is rare and
    /// harmless.
    private func revealSelectedParagraphs() {
        guard let layoutManager = layoutManager as? PaperLayoutManager,
              let storage = textStorage else { return }
        let text = storage.string as NSString
        var active: NSRange?
        for value in selectedRanges {
            let paragraph = text.paragraphRange(for: value.rangeValue.clamped(to: text.length))
            active = active.map { NSUnionRange($0, paragraph) } ?? paragraph
        }
        layoutManager.setActiveRange(active ?? NSRange(location: 0, length: 0))
    }

    /// A frame change makes the text view scroll its insertion point into
    /// view (AppKit's `_setFrameSize:forceScroll:`), and the caret sits at
    /// the top of a freshly opened document. So a band resizing as its
    /// image decodes, or the top margin growing as the window attaches,
    /// left the document scrolled a little down (#49). Typing is the one
    /// frame change that should follow the caret; every other keeps the
    /// viewport where it was.
    override func setFrameSize(_ newSize: NSSize) {
        let clip = enclosingScrollView?.contentView
        let before = clip?.bounds.origin
        let typing = NSApp.currentEvent.map { [.keyDown, .keyUp, .flagsChanged].contains($0.type) } ?? false
        super.setFrameSize(newSize)
        if let clip, let before, !typing, clip.bounds.origin != before {
            let kept = clip.constrainBoundsRect(NSRect(origin: before, size: clip.bounds.size)).origin
            clip.scroll(to: kept)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }

        // A print surface's measure is the page's, whatever the configured
        // maximum; the exporter sizes it with the minimum margins around.
        let margin = isPrintSurface ? Appearance.minimumHorizontalMargin : max(
            Appearance.minimumHorizontalMargin,
            (newSize.width - Appearance.maximumMeasure) / 2
        )
        // A print surface carries no title band and no top margin: the
        // page margins set those, the same on every page.
        let top = isPrintSurface ? 0 : Appearance.topMargin + titleBarHeight
        textContainerInset = NSSize(width: margin, height: top)

        // A block image is fitted to the measure when styled; a window
        // narrower than the measure plus its margins shrinks the container,
        // so the bands are sized again.
        let measure = MarkdownSyntaxStyler.measure(of: self)
        if measure != styledMeasure, hasBlockImages {
            syntaxStyler.apply(to: self)
        }
        styledMeasure = measure
    }

    private var styledMeasure: CGFloat = 0

    /// Set on the offscreen view `PDFExporter` paginates: the document
    /// without the window's chrome around it.
    var isPrintSurface = false

    /// The band under the window's transparent title bar and empty
    /// toolbar. The scroll view no longer insets its content by it
    /// (#61): that inset moved the scroller's track down with the text,
    /// so the knob started well below the top corner while ending at the
    /// bottom one. The text keeps its place by carrying the band in its
    /// own top margin instead; the bottom margin grows by the same amount.
    private var titleBarHeight: CGFloat {
        guard let window else { return 0 }
        return max(window.frame.height - window.contentLayoutRect.height, 0)
    }

    /// The title area's height settles after the view attaches (the chrome
    /// adds the toolbar when the host view sees the window), so the
    /// margin follows `contentLayoutRect`.
    private var contentLayoutObservation: NSKeyValueObservation?

    private func observeTitleBar() {
        contentLayoutObservation = window?.observe(\.contentLayoutRect, options: [.initial]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setFrameSize(self.frame.size)
            }
        }
    }

    private var hasBlockImages: Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        var found = false
        storage.enumerateAttribute(.imageSource, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard value != nil else { return }
            found = true
            stop.pointee = true
        }
        return found
    }

    // MARK: - Image files

    /// One watcher per image file the document shows. A file rewritten in
    /// place or replaced by another program is decoded again and its band
    /// resized, the way the document itself reloads when it changes on disk.
    /// Only files that exist are watched: a missing one would keep the
    /// watcher re-arming, and it is picked up on the next restyle instead.
    private var imageWatchers: [URL: FileWatcher] = [:]

    /// Each watcher holds a file descriptor, a finite resource; a document
    /// naming more images than this keeps their bands but watches only
    /// this many, preferring the ones already watched so churn stays low.
    private static let imageWatcherLimit = 64

    func watchImages(_ urls: Set<URL>) {
        var wanted = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if wanted.count > Self.imageWatcherLimit {
            var capped = Set(wanted.intersection(imageWatchers.keys).prefix(Self.imageWatcherLimit))
            for url in wanted where capped.count < Self.imageWatcherLimit { capped.insert(url) }
            wanted = capped
        }
        for (url, watcher) in imageWatchers where !wanted.contains(url) {
            watcher.cancel()
            imageWatchers[url] = nil
        }
        var added = false
        for url in wanted where imageWatchers[url] == nil {
            imageWatchers[url] = FileWatcher(url: url) { [weak self] in
                self?.imageDidChange(at: url)
            }
            added = true
        }
        // A file newly named (a pasted image, a line typed by hand, a file
        // that has just appeared) is demanded now. The frame and scroll
        // observers cover movement; an edit that adds a band in place
        // moves nothing they watch, and the band stayed a placeholder.
        if added { refreshImageDemand() }
    }

    private func imageDidChange(at url: URL) {
        ImageStore.shared.forget(url)
        syntaxStyler.apply(to: self)
        refreshImageDemand()
        needsDisplay = true
    }

    /// Watchers hold file descriptors and must be cancelled by hand; the
    /// view leaving its window is the document closing, and its image
    /// demand goes with it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        contentLayoutObservation = nil
        observeTitleBar()
        if window == nil {
            for watcher in imageWatchers.values { watcher.cancel() }
            imageWatchers = [:]
            ImageStore.shared.removeDemand(for: ObjectIdentifier(self))
        } else if hasBlockImages {
            syntaxStyler.apply(to: self)
            refreshImageDemand()
        }
    }

    // MARK: - Image demand

    /// The scroll view's clip view is the superview; its bounds are the
    /// viewport, and each change of them is a change of demand.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let observer = clipBoundsObserver {
            NotificationCenter.default.removeObserver(observer)
            clipBoundsObserver = nil
        }
        guard let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        clipBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshImageDemand() }
        }
    }

    private var clipBoundsObserver: NSObjectProtocol?

    /// The text view resizes itself after every relayout, so its own frame
    /// change covers restyling, edits, and a narrower measure resizing the
    /// bands: one observer for every way the bands can move.
    private func observeFrameChanges() {
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshImageDemand() }
        }
    }

    private var refreshingImageDemand = false

    /// Tells the store which images the viewport shows and which lie within
    /// a viewport of it. The viewport is the real one — `visibleRect`, the
    /// clip view's bounds — never the rect AppKit asks to draw, which runs
    /// well past it for responsive scrolling. A view in no window wants
    /// nothing.
    func refreshImageDemand() {
        guard !refreshingImageDemand else { return }
        refreshingImageDemand = true
        defer { refreshingImageDemand = false }
        guard window != nil, hasBlockImages else {
            ImageStore.shared.removeDemand(for: ObjectIdentifier(self))
            return
        }
        let demand = imageDemand(in: visibleRect)
        ImageStore.shared.updateDemand(for: ObjectIdentifier(self), visible: demand.visible, prefetch: demand.prefetch)
    }

    /// The image files whose bands intersect `viewport`, and those whose
    /// bands lie within one viewport height above or below it, each list
    /// in document order without repeats. A file shown twice appears once,
    /// in the higher class.
    func imageDemand(in viewport: NSRect) -> (visible: [URL], prefetch: [URL]) {
        guard let layoutManager = layoutManager as? PaperLayoutManager,
              let container = textContainer else { return ([], []) }
        let reach = viewport.insetBy(dx: 0, dy: -viewport.height).intersection(bounds)
        guard !reach.isEmpty else { return ([], []) }
        let origin = textContainerOrigin
        let containerRect = reach.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: container)
        var visible: [URL] = []
        var prefetch: [URL] = []
        for band in layoutManager.imageBands(forGlyphRange: glyphRange, width: MarkdownSyntaxStyler.measure(of: self)) {
            let placed = band.rect.offsetBy(dx: origin.x, dy: origin.y)
            if placed.intersects(viewport) {
                if !visible.contains(band.url) { visible.append(band.url) }
            } else if placed.intersects(reach) {
                if !prefetch.contains(band.url) { prefetch.append(band.url) }
            }
        }
        prefetch.removeAll { visible.contains($0) }
        return (visible, prefetch)
    }

    /// The rect AppKit proposes spans the whole line fragment, including the
    /// leading added by the line-height multiple. TextKit 1 places that extra
    /// space above the glyphs, so the caret keeps the fragment's bottom edge and
    /// shrinks to the font's ascent plus descent.
    private func caretRect(for proposed: NSRect) -> NSRect {
        let font = caretFont()
        let height = font.ascender - font.descender + Appearance.caretOvershoot * 2
        // The empty document's caret stands in the ghost title, which is
        // drawn from the fragment's top and is taller than the body-sized
        // fragment AppKit proposes — so anchor to the top and keep the
        // title's full height.
        if string.isEmpty {
            // The caret stands where the first letter will land — after
            // the ghost's `# `, which the keystroke inserts — so it does
            // not hop when typing starts.
            let markerWidth = ("# " as NSString).size(withAttributes: [.font: Appearance.bodyFont()]).width
            return NSRect(
                x: proposed.minX + markerWidth,
                y: proposed.minY + ghostTitleTopInset,
                width: Appearance.caretWidth,
                height: height
            )
        }
        let clamped = min(proposed.height, height)
        return NSRect(
            x: proposed.minX,
            y: proposed.maxY - clamped,
            width: Appearance.caretWidth,
            height: clamped
        )
    }

    /// The tallest font on the caret's paragraph. Typing attributes are always
    /// the body font (the styler resets them), so a caret sized from them is
    /// too short on headings; sizing from the paragraph keeps it matched to
    /// the line's text.
    private func caretFont() -> NSFont {
        let body = Appearance.bodyFont()
        // An empty document shows the ghost title, and the first letter
        // typed starts one, so the caret takes the H1 face.
        guard let storage = textStorage, storage.length > 0 else {
            return Appearance.headingFont(size: Appearance.headingSize(level: 1))
        }
        let location = min(selectedRange().location, storage.length)
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        guard paragraph.length > 0 else { return body }

        var tallest = body
        storage.enumerateAttribute(.font, in: paragraph) { value, _, _ in
            if let font = value as? NSFont, font.pointSize > tallest.pointSize {
                tallest = font
            }
        }
        return tallest
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard flag else { return }
        color.setFill()
        NSBezierPath(
            roundedRect: caretRect(for: rect),
            xRadius: Appearance.caretWidth / 2,
            yRadius: Appearance.caretWidth / 2
        ).fill()
    }

    /// Two reasons to enlarge every invalidation: AppKit invalidates only the
    /// 1 pt caret it expects, so the wider bar would leave a trail; and with
    /// fractional line metrics (any non-integer size, line height, or
    /// spacing) the selection highlight and its later erase rect round to
    /// different pixels, leaving thin streaks at fragment edges. Padding by a
    /// pixel each way and snapping to whole pixels covers both.
    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        // The empty document's caret is drawn shifted into the ghost title
        // — right of the marker, lower, and taller than the body-sized rect
        // AppKit invalidates — so the invalidation grows to reach it, or
        // the blink is clipped away and the caret never appears.
        let font = caretFont()
        let dx = string.isEmpty
            ? -(("# " as NSString).size(withAttributes: [.font: Appearance.bodyFont()]).width + Appearance.caretWidth)
            : -Appearance.caretWidth
        let dy = string.isEmpty
            ? -(ghostTitleTopInset + font.ascender - font.descender + Appearance.invalidationPadding)
            : -Appearance.invalidationPadding
        let padded = rect.insetBy(dx: dx, dy: dy).integral
        super.setNeedsDisplay(padded, avoidAdditionalLayout: flag)
    }

    /// Glyphs draw with or without AppKit's font smoothing, per the config.
    /// The flag lives on the context for the length of this draw.
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(Appearance.fontSmoothing)
        super.draw(dirtyRect)
    }

    /// Draws block-quote rules in the margin right after the canvas fill and
    /// before the glyphs. Drawing them in `draw(_:)` fails both ways: before
    /// `super` the background fill covers them, after it the context is
    /// clipped to the text container and the margin is discarded.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCodeBlockBands(in: rect)
        syncCodeCopyButtons()
        drawQuoteRules(in: rect)
        drawThematicBreaks(in: rect)
        drawTaskCircles(in: rect)
        drawImages(in: rect)
        drawImageSelection(in: rect)
        drawPlaceholder()
    }

    /// Block images draw in the band their paragraph spacing reserves,
    /// under the source line, fitted to the measure.
    private func drawImages(in dirtyRect: NSRect) {
        guard let layoutManager = layoutManager as? PaperLayoutManager,
              let container = textContainer else { return }
        let origin = textContainerOrigin
        let containerRect = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: container)
        let bands = layoutManager.imageBands(forGlyphRange: glyphRange, width: MarkdownSyntaxStyler.measure(of: self))
        for band in bands {
            let placed = band.rect.offsetBy(dx: origin.x, dy: origin.y)
            guard placed.intersects(dirtyRect) else { continue }
            let outline = NSBezierPath(
                roundedRect: placed,
                xRadius: Appearance.imageCornerRadius,
                yRadius: Appearance.imageCornerRadius
            )
            // Drawing only looks in the cache: AppKit draws well past the
            // viewport, and a decode per drawn band would pull in every
            // image it prepares. Demand — the real viewport — decodes.
            // Until the bitmap lands the band is a quiet panel the size
            // the image will be; nothing moves when it replaces it.
            guard let entry = ImageStore.shared.residentImage(for: band.url) else {
                Appearance.codeBlockBackground.setFill()
                outline.fill()
                continue
            }
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            entry.image.draw(
                in: placed, from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high]
            )
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// A bitmap decoded off the main actor lands with a notification; a
    /// view whose document shows that file repaints its bands.
    private func observeImageLoads() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(imageDidLoad(_:)),
            name: ImageStore.didLoadNotification,
            object: nil
        )
    }

    /// Only the landed image's own bands repaint, every one of them: a
    /// band AppKit prepared off-screen as a placeholder is redrawn with
    /// the bitmap before it scrolls in, and redrawing is cache-only, so
    /// off-screen bands cost no decode.
    @objc private func imageDidLoad(_ notification: Notification) {
        guard let url = notification.object as? URL,
              let layoutManager = layoutManager as? PaperLayoutManager,
              let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let all = layoutManager.glyphRange(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        for band in layoutManager.imageBands(forGlyphRange: all, width: MarkdownSyntaxStyler.measure(of: self))
        where band.url == url {
            setNeedsDisplay(band.rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: -1))
        }
    }

    /// An empty document ghosts a title where the first line will land, so
    /// a fresh page reads as a page and not a blank canvas. The first
    /// keystroke clears it. The ghost carries the exact attributes a
    /// revealed `# Untitled` line would — marker in the body font at the
    /// syntax ink, word in the H1 face — and sits where TextKit would set
    /// the line (extra line-height leading goes above the glyphs), so the
    /// real title replaces it without anything moving.
    static let placeholderTitle = "Untitled"
    private var placeholderVisible = false

    private static var ghostTitle: NSAttributedString {
        let title = NSMutableAttributedString(
            string: "# ",
            attributes: [.font: Appearance.bodyFont(), .foregroundColor: Appearance.mutedInk]
        )
        title.append(NSAttributedString(
            string: placeholderTitle,
            attributes: [
                .font: Appearance.headingFont(size: Appearance.headingSize(level: 1)),
                .foregroundColor: Appearance.mutedInk,
            ]
        ))
        return title
    }

    /// TextKit places the line-height multiple's extra space above the
    /// glyphs; the ghost (and the caret standing in it) drops by the same
    /// amount to land where the typed title will.
    private var ghostTitleTopInset: CGFloat {
        let font = Appearance.headingFont(size: Appearance.headingSize(level: 1))
        let natural = layoutManager?.defaultLineHeight(for: font)
            ?? (font.ascender - font.descender + font.leading)
        return max(0, (Appearance.lineHeightMultiple - 1) * natural)
    }

    private func drawPlaceholder() {
        guard string.isEmpty, let container = textContainer else {
            placeholderVisible = false
            return
        }
        // The ghost is an editing prompt: a printed empty page stays blank.
        guard NSPrintOperation.current == nil else { return }
        placeholderVisible = true
        let origin = textContainerOrigin
        Self.ghostTitle.draw(
            at: NSPoint(x: origin.x + container.lineFragmentPadding, y: origin.y + ghostTitleTopInset)
        )
    }

    override func didChangeText() {
        super.didChangeText()
        if placeholderVisible != string.isEmpty { needsDisplay = true }
    }

    /// A concealed `---`/`***`/`___` line draws as a hairline across the
    /// measure, vertically centred on its (empty-looking) line fragment.
    private func drawThematicBreaks(in dirtyRect: NSRect) {
        guard let layoutManager = layoutManager as? PaperLayoutManager,
              let container = textContainer else { return }
        let origin = textContainerOrigin
        let containerRect = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: container)
        let rects = layoutManager.thematicBreakRects(forGlyphRange: glyphRange)
        guard !rects.isEmpty else { return }

        Appearance.thematicBreakInk.setFill()
        for fragment in rects {
            NSRect(
                x: origin.x + container.lineFragmentPadding,
                y: origin.y + fragment.midY - Appearance.thematicBreakThickness / 2,
                width: container.size.width - 2 * container.lineFragmentPadding,
                height: Appearance.thematicBreakThickness
            ).fill()
        }
    }

    /// One per code band in the viewport, kept in step by
    /// `syncCodeCopyButtons` (in `CodeCopyButton.swift`).
    var codeCopyButtons: [CodeCopyButton] = []


    private func drawCodeBlockBands(in dirtyRect: NSRect) {
        guard let layoutManager = layoutManager as? PaperLayoutManager,
              let container = textContainer else { return }
        let origin = textContainerOrigin
        let containerRect = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: container)
        let rects = layoutManager.codeBlockRects(forGlyphRange: glyphRange)
        guard !rects.isEmpty else { return }

        Appearance.codeBlockBackground.setFill()
        for rect in rects {
            NSBezierPath(
                roundedRect: NSRect(
                    x: origin.x,
                    y: origin.y + rect.minY,
                    width: container.size.width,
                    height: rect.height
                ),
                xRadius: Appearance.codeBlockCornerRadius,
                yRadius: Appearance.codeBlockCornerRadius
            ).fill()
        }
    }

    private func drawQuoteRules(in dirtyRect: NSRect) {
        guard let layoutManager = layoutManager as? PaperLayoutManager,
              let container = textContainer else { return }
        let origin = textContainerOrigin
        let containerRect = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: container)
        let rects = layoutManager.quoteRuleRects(forGlyphRange: glyphRange)
        guard !rects.isEmpty else { return }

        Appearance.mutedInk.setFill()
        for rect in rects {
            // A pill: the rule's ends are rounded at half its width.
            let rule = NSRect(
                x: origin.x + container.lineFragmentPadding,
                y: origin.y + rect.minY,
                width: Appearance.quoteRuleWidth,
                height: rect.height
            )
            NSBezierPath(
                roundedRect: rule,
                xRadius: Appearance.quoteRuleWidth / 2,
                yRadius: Appearance.quoteRuleWidth / 2
            ).fill()
        }
    }

    // MARK: - List continuation

    /// Return inside a list item starts the next item; Return on an empty
    /// item removes its marker; shift-Return hard-wraps without a marker.
    /// Everything else is an ordinary newline.
    override func insertNewline(_ sender: Any?) {
        guard isEditable, !hasMarkedText(),
              NSApp.currentEvent?.modifierFlags.contains(.shift) != true,
              let edit = ListContinuation.edit(in: string as NSString, selection: selectedRange())
        else {
            super.insertNewline(sender)
            return
        }
        breakUndoCoalescing()
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
    }

    /// Tab in a list item indents the whole item a level; Shift-Tab takes
    /// one back. Anywhere else both keep their ordinary meaning.
    override func insertTab(_ sender: Any?) {
        guard applyListIndent(outdent: false) else { return super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        guard applyListIndent(outdent: true) else { return super.insertBacktab(sender) }
    }

    private func applyListIndent(outdent: Bool) -> Bool {
        guard isEditable, !hasMarkedText(),
              let edit = ListContinuation.indent(in: string as NSString, selection: selectedRange(), outdent: outdent)
        else { return false }
        breakUndoCoalescing()
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return true }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        return true
    }

    // MARK: - Typed substitutions

    /// Typing `>` after `-` replaces the pair with `→`; a word or space
    /// after `--` replaces the pair with `—` (Paper's own smart dashes —
    /// the system's are disabled because they eat `---`). ⌘Z restores the
    /// typed pair. `-->`, `<->`, `---`, and code spans are left as typed.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        // The first letter typed into an empty document starts the title
        // the placeholder promises: it lands as `# ` plus the letter, one
        // undo step, visible in the source. Syntax starters (`#`, `-`,
        // `>`, a backtick, a digit…) are left alone so lists, quotes, and
        // hand-typed headings begin as typed. The insertion carries its
        // styled attributes up front — a paint can land before the styler's
        // pass, and an unstyled `# N` would flash dark and small.
        if self.string.isEmpty, !hasMarkedText(),
           let typed = string as? String ?? (string as? NSAttributedString)?.string,
           typed.count == 1, let scalar = typed.unicodeScalars.first,
           CharacterSet.letters.contains(scalar) {
            let title = NSMutableAttributedString(
                string: "# ",
                attributes: [.font: Appearance.bodyFont(), .foregroundColor: Appearance.mutedInk]
            )
            title.append(NSAttributedString(
                string: typed,
                attributes: [
                    .font: Appearance.headingFont(size: Appearance.headingSize(level: 1)),
                    .foregroundColor: Appearance.ink,
                ]
            ))
            super.insertText(title, replacementRange: replacementRange)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
        guard let typed = string as? String ?? (string as? NSAttributedString)?.string,
              typed.utf16.count == 1, !hasMarkedText() else { return }
        let isDashTrigger = typed == " " || typed.rangeOfCharacter(from: .alphanumerics) != nil
        guard typed == ">" || typed == "]" || isDashTrigger else { return }
        // On the next pass of the run loop, after the keystroke's undo group
        // has closed, so the substitution is its own undo step.
        pendingSubstitution?.invalidate()
        pendingSubstitution = Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.replaceTypedArrow()
                self?.replaceTypedDashes()
                self?.replaceTypedTaskBox()
            }
        }
    }

    private var pendingSubstitution: Timer?

    /// Runs a scheduled substitution now. Tests use it instead of pumping
    /// the run loop, which is not safe inside the document-based test host.
    func flushPendingSubstitution() {
        guard let pendingSubstitution else { return }
        pendingSubstitution.fire()
        pendingSubstitution.invalidate()
        self.pendingSubstitution = nil
    }

    private func replaceTypedArrow() {
        pendingSubstitution = nil
        guard selectedRange().length == 0 else { return }
        let caret = selectedRange().location
        let text = self.string as NSString
        guard caret >= 2, text.character(at: caret - 1) == 0x3E, text.character(at: caret - 2) == 0x2D else { return }
        if caret >= 3 {
            let before = text.character(at: caret - 3)
            if before == 0x2D || before == 0x3C { return }
        }
        if let font = textStorage?.attribute(.font, at: caret - 2, effectiveRange: nil) as? NSFont, font == Appearance.codeFont() { return }
        let pair = NSRange(location: caret - 2, length: 2)
        // Typing is coalesced into one undo action; close it on both sides
        // so ⌘Z after the substitution gives back the typed pair.
        breakUndoCoalescing()
        guard shouldChangeText(in: pair, replacementString: "→") else { return }
        textStorage?.replaceCharacters(in: pair, with: "→")
        didChangeText()
        setSelectedRange(NSRange(location: pair.location + 1, length: 0))
        breakUndoCoalescing()
    }

    /// `--` becomes `—` when the character after it lands — never a third
    /// `-` (so `---` rules and front-matter fences survive), never after a
    /// `-`, `|`, `:`, `<` or `>` (runs, tables, arrows), never in code.
    private func replaceTypedDashes() {
        guard selectedRange().length == 0 else { return }
        let caret = selectedRange().location
        let text = self.string as NSString
        guard caret >= 3,
              // The trigger is the just-typed word character or space — a
              // third `-` keeps a rule typeable and `>` keeps `-->` literal.
              ![0x2D, 0x3E].contains(text.character(at: caret - 1)),
              text.character(at: caret - 2) == 0x2D,
              text.character(at: caret - 3) == 0x2D else { return }
        if caret >= 4 {
            let before = text.character(at: caret - 4)
            if [0x2D, 0x7C, 0x3A, 0x3C, 0x3E].contains(before) { return }
        }
        if let font = textStorage?.attribute(.font, at: caret - 2, effectiveRange: nil) as? NSFont,
           font == Appearance.codeFont() { return }
        let pair = NSRange(location: caret - 3, length: 2)
        breakUndoCoalescing()
        guard shouldChangeText(in: pair, replacementString: "—") else { return }
        textStorage?.replaceCharacters(in: pair, with: "—")
        didChangeText()
        setSelectedRange(NSRange(location: caret - 1, length: 0))
        breakUndoCoalescing()
    }

    /// The line before a typed `[]`: indent, any quote prefix, and
    /// optionally a list marker with its gap. Anything else and the
    /// brackets are prose.
    private static let taskBoxLeadPattern = try! NSRegularExpression(
        pattern: #"^[\t ]*(?:>[\t ]?)*(?:(?:[-+*]|\d+[A-Za-z]?[.)])[\t ]+)?$"#
    )

    /// `[]` at the start of a line's content becomes an open task: `[]`
    /// alone becomes `- [ ] `, and `- []` becomes `- [ ] `, the caret after
    /// the space. Never mid-line, never in code.
    private func replaceTypedTaskBox() {
        guard selectedRange().length == 0 else { return }
        let caret = selectedRange().location
        let text = self.string as NSString
        guard caret >= 2, text.character(at: caret - 1) == 0x5D, text.character(at: caret - 2) == 0x5B else { return }
        let paragraph = text.paragraphRange(for: NSRange(location: caret, length: 0))
        let lead = NSRange(location: paragraph.location, length: caret - 2 - paragraph.location)
        guard let match = Self.taskBoxLeadPattern.firstMatch(in: text as String, range: lead),
              match.range == lead else { return }
        if let font = textStorage?.attribute(.font, at: caret - 2, effectiveRange: nil) as? NSFont,
           font == Appearance.codeFont() { return }
        let leadText = text.substring(with: lead)
        let hasMarker = MarkdownSyntaxStyler.listMarkerPattern.firstMatch(
            in: leadText, range: NSRange(location: 0, length: leadText.utf16.count)
        ) != nil
        let pair = NSRange(location: caret - 2, length: 2)
        let replacement = hasMarker ? "[ ] " : "- [ ] "
        breakUndoCoalescing()
        guard shouldChangeText(in: pair, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: pair, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: pair.location + replacement.utf16.count, length: 0))
        breakUndoCoalescing()
    }

    // MARK: - Image paste and drop (#36)

    /// A plain-text view reads only text types, and AppKit disables Paste
    /// (so ⌘V beeps) when the pasteboard holds none of them. Images and
    /// files are declared readable so a screenshot reaches `paste`.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        for type in [NSPasteboard.PasteboardType.png, .tiff, .fileURL] where !types.contains(type) {
            types.append(type)
        }
        return types
    }

    /// An image on the clipboard lands beside the document and inserts a
    /// block image line; anything else pastes as text, as before.
    override func paste(_ sender: Any?) {
        if pasteImage(from: .general, at: selectedRange()) { return }
        super.paste(sender)
    }

    /// A Finder drop of an image file rides the paste path, at the point
    /// dropped. AppKit's own handling would insert the file's path as text.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard ImagePaste.imageFileURL(on: pasteboard) != nil else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        return pasteImage(from: pasteboard, at: NSRange(location: index, length: 0))
    }

    /// The subfolder pasted images go to, relative to the document; nil
    /// reads the config. Tests set it directly.
    var imagePasteDirectory: String?

    /// Writes the image on `pasteboard` beside the document and inserts a
    /// block image at `range`. False when the pasteboard holds no image, so
    /// the caller falls through to ordinary text. An unsaved document has
    /// no folder to write into: the save sheet runs first and the paste
    /// continues once the file exists, or not at all when the sheet is
    /// cancelled.
    @discardableResult
    func pasteImage(from pasteboard: NSPasteboard, at range: NSRange) -> Bool {
        guard isEditable, !hasMarkedText(), let source = ImagePaste.source(on: pasteboard) else { return false }
        if let documentURL {
            insertImage(source, beside: documentURL, at: range)
        } else {
            saveThenInsert(source, at: range)
        }
        return true
    }

    private var pendingImage: (source: ImagePaste.Source, range: NSRange)?

    private func saveThenInsert(_ source: ImagePaste.Source, at range: NSRange) {
        guard let document = hostDocument else { NSSound.beep(); return }
        pendingImage = (source, range)
        document.save(withDelegate: self, didSave: #selector(document(_:didSave:contextInfo:)), contextInfo: nil)
    }

    /// The NSDocument behind this window: SwiftUI's document group wraps
    /// the file document in one and hangs it on the window controller.
    private var hostDocument: NSDocument? {
        if let document = window?.windowController?.document as? NSDocument { return document }
        return NSDocumentController.shared.documents.first { document in
            document.windowControllers.contains { $0.window == window }
        }
    }

    @objc private func document(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        defer { pendingImage = nil }
        guard didSave, let url = document.fileURL, let pending = pendingImage else { return }
        // The editor pushes the new URL in on its next update; the band
        // should render now.
        documentURL = url
        insertImage(pending.source, beside: url, at: pending.range.clamped(to: (string as NSString).length))
    }

    private func insertImage(_ source: ImagePaste.Source, beside documentURL: URL, at range: NSRange) {
        let directory = imagePasteDirectory ?? ConfigurationStore.shared.current.imagePasteDirectory
        let destination: String
        do {
            destination = try ImagePaste.write(source, beside: documentURL, directory: directory)
        } catch {
            presentError(error)
            return
        }
        let edit = ImagePaste.insertion(of: destination, replacing: range, in: string as NSString)
        // Its own undo step: ⌘Z takes the line back out. The file stays,
        // a deliberate choice against silently deleting a user's file.
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        breakUndoCoalescing()
    }

    // MARK: - Inline formatting (Format menu, ⌘B ⌘I ⌘U ⌘E)

    @objc func toggleBold(_ sender: Any?) { toggle(.bold) }
    @objc func toggleItalic(_ sender: Any?) { toggle(.italic) }
    @objc func toggleUnderline(_ sender: Any?) { toggle(.underline) }
    @objc func toggleStrikethrough(_ sender: Any?) { toggle(.strikethrough) }
    @objc func toggleCode(_ sender: Any?) { toggle(.code) }

    /// ⌘K: the selection (or word) becomes link text; the destination is
    /// the clipboard when it holds a URL, otherwise the caret waits inside
    /// the parentheses.
    @objc func insertLink(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { return }
        let text = string as NSString
        var range = selectedRange()
        if range.length == 0 { range = InlineFormat.wordRange(at: range.location, in: text) }
        let label = text.substring(with: range)
        let clipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let destination = Self.looksLikeURL(clipboard) ? clipboard : ""
        let replacement = "[\(label)](\(destination))"
        let selection: NSRange
        if destination.isEmpty {
            selection = NSRange(location: range.location + label.utf16.count + 3, length: 0)
        } else if label.isEmpty {
            selection = NSRange(location: range.location + 1, length: 0)
        } else {
            selection = NSRange(location: range.location + replacement.utf16.count, length: 0)
        }
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(selection)
    }

    static func looksLikeURL(_ string: String) -> Bool {
        MarkdownResource.isRemote(string)
    }

    /// A clean click on link text opens its destination — the caret goes in
    /// by clicking beside the link or dragging across it. ⌘-click opens too.
    /// A click on a block image is the image's alone (see `clickImage`).
    /// `super.mouseDown` runs the whole tracking loop, so afterwards a drag
    /// shows up as a non-empty selection and the click is left alone.
    override func mouseDown(with event: NSEvent) {
        if pressIsInTitleBand(event) { return handleTitleBandPress(event) }
        let destination = linkDestination(at: event)
        if event.modifierFlags.contains(.command), let destination {
            open(destination)
            return
        }
        let unmodified = event.modifierFlags.intersection([.shift, .control, .option]).isEmpty
        if unmodified, clickImage(with: event) { return }
        if unmodified, event.clickCount == 1, toggleTaskBox(at: convert(event.locationInWindow, from: nil)) { return }
        selectedImage = nil
        let plainClick = event.clickCount == 1 && unmodified
        super.mouseDown(with: event)
        if plainClick, let destination, selectedRange().length == 0,
           let up = NSApp.currentEvent, up.type == .leftMouseUp,
           linkDestination(at: up) == destination {
            open(destination)
        }
    }

    /// The band under the transparent title bar lies over the text view
    /// since it took over the title inset (#61), so a press there would
    /// start a selection and the window had nowhere to be grabbed (#65).
    /// The band is the title bar: a press drags the window and a
    /// double-click does what the title bar's would.
    /// The grab band is the traffic lights' row, not the whole title area:
    /// as far below the close button as the button sits below the top.
    private func pressIsInTitleBand(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        var floor = window.contentLayoutRect.maxY
        if let close = window.standardWindowButton(.closeButton), let superview = close.superview {
            let button = superview.convert(close.frame, to: nil)
            floor = max(floor, button.minY - (window.frame.height - button.maxY))
        }
        return event.locationInWindow.y > floor
    }

    private func handleTitleBandPress(_ event: NSEvent) {
        guard let window else { return }
        guard event.clickCount == 2 else { return window.performDrag(with: event) }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }

    /// A click on a task item's circle (the point in view coordinates) flips
    /// the source between `[ ]` and `[x]`, undoably, and leaves the caret
    /// where it was. False when the point is not on a circle, and the click
    /// places the caret as anywhere else.
    @discardableResult
    func toggleTaskBox(at point: NSPoint) -> Bool {
        guard isEditable, let storage = textStorage, storage.length > 0,
              let layoutManager = layoutManager as? PaperLayoutManager,
              let container = textContainer else { return false }
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(
            for: containerPoint, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        guard index < storage.length else { return false }
        var prefix = NSRange(location: NSNotFound, length: 0)
        guard storage.attribute(.taskBox, at: index, longestEffectiveRange: &prefix,
                                in: NSRange(location: 0, length: storage.length)) != nil,
              let circle = taskCircleRect(forPrefix: prefix),
              circle.insetBy(dx: -3, dy: -3).contains(containerPoint) else { return false }

        let inner = NSRange(location: NSMaxRange(prefix) - 2, length: 1)
        let done = (storage.string as NSString).substring(with: inner) != " "
        let replacement = done ? " " : "x"
        breakUndoCoalescing()
        guard shouldChangeText(in: inner, replacementString: replacement) else { return false }
        storage.replaceCharacters(in: inner, with: replacement)
        didChangeText()
        breakUndoCoalescing()
        animateTaskCircle(atPrefix: prefix.location)
        return true
    }

    /// The circle for the task prefix at `prefix`, in text-container
    /// coordinates: the diameter square sitting on the baseline's cap
    /// height where the `[` renders. The prefix conceals on the active
    /// paragraph as well, so the circle is there whatever the caret does.
    private func taskCircleRect(forPrefix prefix: NSRange) -> NSRect? {
        guard prefix.length >= 3, let layoutManager = layoutManager as? PaperLayoutManager,
              let container = textContainer, let storage = textStorage,
              layoutManager.isConcealed(characterAt: NSMaxRange(prefix) - 1) else { return nil }
        let index = NSMaxRange(prefix) - 3
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
        let location = layoutManager.location(forGlyphAt: glyph)
        let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont ?? Appearance.bodyFont()
        let size = Appearance.taskBoxSize
        let baseline = fragment.minY + location.y
        return NSRect(
            x: fragment.minX + location.x,
            y: baseline - font.capHeight / 2 - size / 2,
            width: size,
            height: size
        )
    }

    /// Task circles: a ring in the rule ink for an open item, a disc in the
    /// text ink with a check in the canvas colour for a done one. Drawn
    /// under the glyphs, in the room the item's concealed `[ ]` reserves.
    private func drawTaskCircles(in dirtyRect: NSRect) {
        guard let layoutManager = layoutManager as? PaperLayoutManager,
              let container = textContainer, let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let containerRect = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        storage.enumerateAttribute(.taskBox, in: characters) { value, run, _ in
            guard let box = value as? String, let rect = taskCircleRect(forPrefix: run) else { return }
            let circle = rect.offsetBy(dx: origin.x, dy: origin.y)
            let done = box != "[ ]"
            // A nested task draws as a rounded square, so the levels read
            // apart at a glance (Will's suggestion).
            let nested = Self.isNestedTask(prefixAt: run.location, in: storage.string as NSString)
            let shape: (NSRect) -> NSBezierPath = { rect in
                nested
                    ? NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.28, yRadius: rect.width * 0.28)
                    : NSBezierPath(ovalIn: rect)
            }
            // The disc's share of the circle: full when done, none when
            // open, in between while a flip animates.
            var fill: CGFloat = done ? 1 : 0
            if let animation = taskAnimation, animation.prefix == run.location {
                let progress = min(1, (CACurrentMediaTime() - animation.start) / Self.taskAnimationDuration)
                let eased = 1 - pow(1 - progress, 3)
                fill = done ? eased : 1 - eased
            }
            if fill < 1 {
                let ring = shape(circle.insetBy(dx: Appearance.taskBoxStroke / 2, dy: Appearance.taskBoxStroke / 2))
                ring.lineWidth = Appearance.taskBoxStroke
                Appearance.thematicBreakInk.setStroke()
                ring.stroke()
            }
            guard fill > 0 else { return }
            let inset = circle.width * (1 - fill) / 2
            let disc = circle.insetBy(dx: inset, dy: inset)
            Appearance.ink.setFill()
            shape(disc).fill()
            if let check = Self.checkmark {
                // The symbol sits a little below centre optically; nudge it
                // up by a hair and scale it with the disc.
                let side = disc.width * 0.56
                let target = NSRect(
                    x: disc.midX - side / 2, y: disc.midY - side / 2 - disc.width * 0.02,
                    width: side, height: side
                )
                check.draw(in: target, from: .zero, operation: .sourceOver, fraction: fill, respectFlipped: true, hints: nil)
            }
        }
    }

    /// A task whose marker is indented under another item: whitespace
    /// stands between the line start and the prefix.
    nonisolated static func isNestedTask(prefixAt location: Int, in text: NSString) -> Bool {
        guard location > 0 else { return false }
        let previous = text.character(at: location - 1)
        return previous == 0x20 || previous == 0x09
    }

    /// SF Symbols' checkmark, in the canvas colour, cut out of a done disc.
    /// The symbol rasterised once per canvas colour: a symbol image draws
    /// nothing into a PDF context (the print pass), a bitmap draws
    /// anywhere, and at 256 px it is crisp at any disc the text can set.
    private static var checkmarks: [NSColor: NSImage] = [:]

    private static var checkmark: NSImage? {
        let canvas = Appearance.canvas
        if let cached = checkmarks[canvas] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: 64, weight: .bold)
            .applying(.init(paletteColors: [canvas]))
        guard let symbol = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let side = 256
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        symbol.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil
        )
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        checkmarks[canvas] = image
        return image
    }

    /// The flip in progress: the prefix it belongs to and when it began.
    /// The disc grows out of the ring on a check and shrinks back on an
    /// uncheck, redrawn by a timer until the duration is up.
    private var taskAnimation: (prefix: Int, start: CFTimeInterval)?
    private var taskAnimationTimer: Timer?
    private static let taskAnimationDuration: CFTimeInterval = 0.22

    private func animateTaskCircle(atPrefix prefix: Int) {
        taskAnimationTimer?.invalidate()
        taskAnimation = (prefix, CACurrentMediaTime())
        // The timer fires on the main run loop; the closure hops into the
        // actor the way the layout-complete delegate does.
        taskAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard let animation = self.taskAnimation else {
                    self.taskAnimationTimer?.invalidate()
                    self.taskAnimationTimer = nil
                    return
                }
                self.redrawTaskCircle(atPrefix: animation.prefix)
                if CACurrentMediaTime() - animation.start >= Self.taskAnimationDuration {
                    self.taskAnimationTimer?.invalidate()
                    self.taskAnimationTimer = nil
                    self.taskAnimation = nil
                    self.redrawTaskCircle(atPrefix: animation.prefix)
                }
            }
        }
    }

    private func redrawTaskCircle(atPrefix prefix: Int) {
        guard let storage = textStorage, prefix < storage.length else { return }
        var run = NSRange(location: NSNotFound, length: 0)
        guard storage.attribute(.taskBox, at: prefix, longestEffectiveRange: &run, in: NSRange(location: 0, length: storage.length)) != nil,
              let rect = taskCircleRect(forPrefix: run) else { return }
        let origin = textContainerOrigin
        setNeedsDisplay(rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: -2))
    }

    private func linkDestination(at event: NSEvent) -> String? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        guard index < storage.length else { return nil }
        return storage.attribute(.linkDestination, at: index, effectiveRange: nil) as? String
    }

    /// Absolute URLs open as they are; a `#fragment` jumps to its heading
    /// in this document; anything else is a path relative to the document,
    /// and stays closed while the document is unsaved.
    private func open(_ destination: String) {
        if destination.hasPrefix("#") {
            jump(toFragment: destination)
            return
        }
        guard let url = linkURL(for: destination) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Places the caret on the heading the fragment names and scrolls it
    /// into view; a fragment naming no heading is a no-op.
    func jump(toFragment fragment: String) {
        guard let range = MarkdownSyntaxStyler.fragmentRange(fragment, in: string) else { return }
        setSelectedRange(NSRange(location: range.location, length: 0))
        scrollRangeToVisible(range)
    }

    func linkURL(for destination: String) -> URL? {
        if MarkdownResource.isRemote(destination) { return URL(string: destination) }
        return MarkdownResource.localURL(for: destination, relativeTo: documentURL)
    }

    private func toggle(_ format: InlineFormat) {
        guard isEditable, !hasMarkedText() else { return }
        let edit = format.toggle(in: string as NSString, selection: selectedRange())
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        insertionPointColor = Appearance.ink
        syntaxStyler.apply(to: self)
    }

    /// Configuration changes apply to every open window as soon as the file
    /// is saved. Selector observers are unregistered automatically on
    /// deallocation.
    private func observeSettings() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: Configuration.didChangeNotification,
            object: nil
        )
    }

    @objc private func settingsDidChange() {
        font = Appearance.bodyFont()
        applyColors()
        applyChecking()
        setFrameSize(frame.size)
        syntaxStyler.apply(to: self)
        needsDisplay = true
    }

    private func applyColors() {
        backgroundColor = Appearance.canvas
        textColor = Appearance.ink
        insertionPointColor = Appearance.ink
        var selected: [NSAttributedString.Key: Any] = [.backgroundColor: Appearance.selection]
        if let ink = Appearance.selectionInk { selected[.foregroundColor] = ink }
        selectedTextAttributes = selected
        enclosingScrollView?.backgroundColor = Appearance.canvas
    }

    /// Spelling and grammar checking follow the config. Turning one off
    /// takes its marks off the document at once; AppKit would otherwise
    /// leave the underlines until the next edit touched them.
    private func applyChecking() {
        let configuration = Appearance.configuration
        let spelling = configuration.spelling
        let grammar = configuration.grammar
        if isContinuousSpellCheckingEnabled != spelling { isContinuousSpellCheckingEnabled = spelling }
        if isGrammarCheckingEnabled != grammar { isGrammarCheckingEnabled = grammar }
        guard !spelling || !grammar, let storage = textStorage, let layoutManager, storage.length > 0 else { return }
        let whole = NSRange(location: 0, length: storage.length)
        if !spelling, !grammar {
            layoutManager.removeTemporaryAttribute(.spellingState, forCharacterRange: whole)
            return
        }
        // One of the two is off: drop only its marks, which the spelling
        // state flags apart.
        let dropped: NSAttributedString.SpellingState = spelling ? .grammar : .spelling
        var index = 0
        while index < whole.length {
            var range = NSRange(location: index, length: 0)
            let value = layoutManager.temporaryAttribute(
                .spellingState, atCharacterIndex: index, longestEffectiveRange: &range, in: whole
            )
            if let raw = value as? Int, raw & dropped.rawValue != 0 {
                layoutManager.removeTemporaryAttribute(.spellingState, forCharacterRange: range)
            }
            index = max(NSMaxRange(range), index + 1)
        }
    }

    /// Code is not prose, and neither is the address of a link or an
    /// image. Every annotation continuous checking wants to make —
    /// spelling and grammar underlines, quote and text replacements —
    /// arrives here first, so results touching a fenced block, an inline
    /// span, or a `(destination)` are dropped and the rest of the document
    /// keeps its checking.
    override func handleTextCheckingResults(
        _ results: [NSTextCheckingResult],
        forRange range: NSRange,
        types checkingTypes: NSTextCheckingTypes,
        options: [NSSpellChecker.OptionKey: Any] = [:],
        orthography: NSOrthography,
        wordCount: Int
    ) {
        super.handleTextCheckingResults(
            proseResults(results),
            forRange: range,
            types: checkingTypes,
            options: options,
            orthography: orthography,
            wordCount: wordCount
        )
    }

    /// The results that touch no code and no address, less the spelling
    /// results on tokens that are not words (`SpellCheckFilter`).
    func proseResults(_ results: [NSTextCheckingResult]) -> [NSTextCheckingResult] {
        let text = string as NSString
        return results.filter { result in
            guard !touchesCode(result.range) else { return false }
            guard result.resultType == .spelling else { return true }
            return SpellCheckFilter.keepsMark(at: result.range, in: text)
        }
    }

    /// Whether any character in `range` is code — inside a fenced block
    /// (the `.codeBlock` mark) or an inline span (the chip background, the
    /// same mark the layout manager rounds) — or a link or image address.
    func touchesCode(_ range: NSRange) -> Bool {
        guard let storage = textStorage else { return false }
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard clipped.length > 0 else { return false }
        var found = false
        storage.enumerateAttributes(in: clipped) { attributes, _, stop in
            if Self.isCode(attributes) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    nonisolated static func isCode(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        if attributes[.codeBlock] != nil || attributes[.address] != nil { return true }
        guard let color = attributes[.backgroundColor] as? NSColor else { return false }
        return MainActor.assumeIsolated { color == Appearance.codeBlockBackground }
    }

    /// The checker can run on text before it is styled — on a freshly
    /// opened document, or on a span typed before its closing backtick —
    /// and its marks are temporary attributes that a restyle leaves
    /// alone. So every restyle takes them off whatever is code now, in
    /// the range it restyled.
    func clearCheckingMarksInCode(in range: NSRange) {
        guard let storage = textStorage, let layoutManager, range.length > 0 else { return }
        storage.enumerateAttributes(in: range) { attributes, range, _ in
            guard Self.isCode(attributes) else { return }
            layoutManager.removeTemporaryAttribute(.spellingState, forCharacterRange: range)
        }
    }

    private func configure() {
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true

        // Drawing the canvas here keeps the view opaque, so scrolling can
        // blit the existing pixels instead of redrawing every visible line.
        drawsBackground = true
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isContinuousSpellCheckingEnabled = Appearance.configuration.spelling
        isGrammarCheckingEnabled = Appearance.configuration.grammar
        isAutomaticQuoteSubstitutionEnabled = true
        // The system's dash substitution is syntax-blind: it eats the second
        // `-` of a thematic break or front-matter fence. Paper does its own,
        // Markdown-aware, in the typed-substitution path.
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = true
        isAutomaticSpellingCorrectionEnabled = false
        // No Writing Tools: the selection affordance and panel are exactly
        // the kind of chrome Paper exists to remove.
        writingToolsBehavior = .none

        font = Appearance.bodyFont()
        applyColors()
        typingAttributes = MarkdownSyntaxStyler.baseAttributes
    }
}

// MARK: - Edits

extension PaperTextView: NSTextStorageDelegate {
    /// Every change to the characters, however it was made (typing, paste,
    /// undo, a typed substitution, a list continuation), reaches the styler
    /// here, so the restyle after it can stay local to the edit.
    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        // The storage is edited on the main thread only; the protocol is
        // not annotated, so the isolation is asserted here.
        MainActor.assumeIsolated { syntaxStyler.noteEdit(editedRange, delta: delta) }
    }
}
