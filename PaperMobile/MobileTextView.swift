import UIKit

/// Paper's page on iOS: a `UITextView` on TextKit 1, styled by the shared
/// `MarkdownSyntaxStyler` and laid out by the shared `PaperLayoutManager`,
/// as `PaperTextView` is on the Mac. The page's decorations (code bands,
/// quote rules, breaks, tables, task circles, images, math) draw in a
/// `DecorationView` behind the text, since `UITextView` has no
/// `drawBackground(in:)` to draw them in.
///
/// TextKit 1 is chosen by `init(frame:textContainer:)` with a container
/// whose layout manager is Paper's. Nothing here may touch
/// `textLayoutManager`, which would move the view to TextKit 2.
final class MobileTextView: UITextView {
    let syntaxStyler = MarkdownSyntaxStyler()

    /// The document's file, so relative links and images resolve; nil
    /// until the first save.
    var documentURL: URL? {
        didSet {
            guard documentURL != oldValue else { return }
            restyle()
        }
    }

    var paperLayoutManager: PaperLayoutManager {
        // Set in `init` and never replaced.
        layoutManager as! PaperLayoutManager
    }

    private let decorations = DecorationView()
    private var styledMeasure: CGFloat = 0

    /// Called with the whole text after every edit, for the document.
    var onTextChange: ((String) -> Void)?
    /// The selection before the current change, for snapping out of list
    /// prefixes; and whether the snap itself is being applied.
    var previousSelection: NSRange?
    var adjustingSelection = false
    /// Takes taps on task circles and links; see `gestureRecognizerShouldBegin`.
    private(set) var actionTap: UITapGestureRecognizer?

    /// The side margin on a phone; the Mac's 64 pt minimum would leave a
    /// narrow column. The top margin is smaller for the same reason.
    static let compactMargin: CGFloat = 20
    static let compactTopMargin: CGFloat = 28

    init() {
        let storage = NSTextStorage()
        let layoutManager = PaperLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)

        storage.delegate = self
        configure()
        layoutManager.usedBottomDidShrink = { [weak self] _, _ in
            self?.decorations.setNeedsDisplay()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(imageDidLoad(_:)), name: ImageStore.didLoadNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange), name: Configuration.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil
        )
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self]) { (view: MobileTextView, _) in
            view.setNeedsLayout()
            view.restyle()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        isEditable = true
        isSelectable = true
        delegate = self
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        // As on the Mac: the system's dashes are off because they eat
        // `---`, and Paper substitutes its own; quotes stay smart. Pasting
        // must not add spaces. Autocorrection is left to the system, which
        // a phone keyboard needs.
        smartQuotesType = .yes
        smartDashesType = .no
        smartInsertDeleteType = .no
        dataDetectorTypes = []
        inputAccessoryView = KeyboardRow(textView: self)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        actionTap = tap
        decorations.isUserInteractionEnabled = false
        decorations.backgroundColor = .clear
        decorations.isOpaque = false
        decorations.contentMode = .redraw
        decorations.textView = self
        insertSubview(decorations, at: 0)
        applyColors()
        font = Appearance.bodyFont()
        typingAttributes = MarkdownSyntaxStyler.baseAttributes
    }

    private func applyColors() {
        backgroundColor = Appearance.canvas
        tintColor = Appearance.ink
    }

    // MARK: - Text

    /// Replaces the text and styles all of it, keeping the selection where
    /// it still fits.
    func load(_ source: String) {
        let selection = selectedRange
        text = source
        restyle()
        selectedRange = selection.clamped(to: source.utf16.count)
    }

    func restyle() {
        syntaxStyler.apply(to: self)
        styledMeasure = MarkdownSyntaxStyler.measure(of: self)
        decorations.setNeedsDisplay()
        refreshImageDemand()
    }

    /// The page runs under the keyboard and its bar (see the document
    /// view), so the text view insets its content by the part of itself
    /// the keyboard covers. Text can still scroll beneath the glass bar,
    /// where the bottom edge effect fades it.
    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let window, let screenFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let hiding = note.name == UIResponder.keyboardWillHideNotification
        let keyboard = convert(window.convert(screenFrame, from: window.screen.coordinateSpace), from: window)
        let covered = hiding ? 0 : max(0, bounds.maxY - max(keyboard.minY, bounds.minY))
        // The automatic adjustment already adds the home indicator's inset.
        let inset = max(0, covered - safeAreaInsets.bottom)
        guard contentInset.bottom != inset else { return }
        contentInset.bottom = inset
        verticalScrollIndicatorInsets.bottom = inset
        if !hiding { scrollRangeToVisible(selectedRange) }
    }

    /// Tells the enclosing view controller this is its content scroll view,
    /// so the navigation bar fades text scrolling under it.
    private func claimTopEdge() {
        var responder: UIResponder? = self
        while let next = responder?.next, !(next is UIViewController) { responder = next }
        (responder?.next as? UIViewController)?.setContentScrollView(self, for: .top)
    }

    @objc private func settingsDidChange() {
        applyColors()
        font = Appearance.bodyFont()
        setNeedsLayout()
        restyle()
    }

    // MARK: - Geometry

    /// The text container's origin in the view, as AppKit names it.
    var textContainerOrigin: CGPoint {
        CGPoint(x: textContainerInset.left, y: textContainerInset.top)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateInsets()
        placeDecorations()
        refreshImageDemand()
    }

    /// The measure centres on wide screens; a phone keeps a small margin.
    private func updateInsets() {
        let width = bounds.width
        guard width > 0 else { return }
        let compact = traitCollection.horizontalSizeClass == .compact
        let minimum = compact ? Self.compactMargin : Appearance.minimumHorizontalMargin
        let margin = max(minimum, ((width - Appearance.maximumMeasure) / 2).rounded())
        let top = compact ? Self.compactTopMargin : Appearance.topMargin
        let inset = UIEdgeInsets(top: top, left: margin, bottom: top * 2, right: margin)
        guard inset != textContainerInset else { return }
        textContainerInset = inset
        // A block image and a table are fitted to the measure when styled.
        let measure = MarkdownSyntaxStyler.measure(of: self)
        if measure != styledMeasure, hasTables || hasBlockImages {
            restyle()
        }
        styledMeasure = measure
    }

    /// The decoration view covers the viewport and a screen above and
    /// below it, and moves (and redraws) only when the viewport leaves
    /// that band, so ordinary scrolling draws nothing.
    private func placeDecorations() {
        let viewport = CGRect(origin: contentOffset, size: bounds.size)
        guard viewport.width > 0, viewport.height > 0 else { return }
        let current = decorations.frame
        if current.width != viewport.width || !current.contains(viewport) {
            decorations.frame = viewport.insetBy(dx: 0, dy: -viewport.height).integral
            decorations.setNeedsDisplay()
        }
        if subviews.first !== decorations { sendSubviewToBack(decorations) }
    }

    /// Layout changed under the decorations (a restyle, an edit, a band
    /// resized): draw them again where they are.
    func decorationsNeedDisplay() {
        decorations.setNeedsDisplay()
    }

    private var hasTables: Bool { contains(.tableRow) }
    private var hasBlockImages: Bool { contains(.imageSource) }

    private func contains(_ key: NSAttributedString.Key) -> Bool {
        guard textStorage.length > 0 else { return false }
        var found = false
        textStorage.enumerateAttribute(key, in: NSRange(location: 0, length: textStorage.length)) { value, _, stop in
            guard value != nil else { return }
            found = true
            stop.pointee = true
        }
        return found
    }

    // MARK: - Images

    /// Tells the store which images the viewport shows and which lie within
    /// a viewport of it, as the Mac's text view does.
    func refreshImageDemand() {
        guard window != nil, hasBlockImages else {
            ImageStore.shared.removeDemand(for: ObjectIdentifier(self))
            return
        }
        let viewport = CGRect(origin: contentOffset, size: bounds.size)
        let reach = viewport.insetBy(dx: 0, dy: -viewport.height)
        let origin = textContainerOrigin
        let glyphRange = paperLayoutManager.glyphRange(
            forBoundingRect: reach.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer
        )
        var visible: [URL] = []
        var prefetch: [URL] = []
        for band in paperLayoutManager.imageBands(forGlyphRange: glyphRange, width: MarkdownSyntaxStyler.measure(of: self)) {
            let placed = band.rect.offsetBy(dx: origin.x, dy: origin.y)
            if placed.intersects(viewport) {
                if !visible.contains(band.url) { visible.append(band.url) }
            } else if placed.intersects(reach), !prefetch.contains(band.url) {
                prefetch.append(band.url)
            }
        }
        prefetch.removeAll { visible.contains($0) }
        ImageStore.shared.updateDemand(for: ObjectIdentifier(self), visible: visible, prefetch: prefetch)
    }

    @objc private func imageDidLoad(_ notification: Notification) {
        decorations.setNeedsDisplay()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            ImageStore.shared.removeDemand(for: ObjectIdentifier(self))
        } else {
            refreshImageDemand()
            claimTopEdge()
        }
    }
}

// MARK: - Styled surface

extension MobileTextView: StyledSurface {
    var surfaceStorage: NSTextStorage? { textStorage }
    var surfaceContainer: NSTextContainer? { textContainer }
    var surfaceSelection: NSRange {
        get { selectedRange }
        set { selectedRange = newValue }
    }
    var surfaceTypingAttributes: [NSAttributedString.Key: Any] {
        get { typingAttributes }
        set { typingAttributes = newValue }
    }
    var surfaceDocumentURL: URL? { documentURL }
    var surfaceIsPrinting: Bool { false }
    var surfacePrintPage: PrintStyle.Page? { nil }
    /// The system checker cannot be filtered per range on iOS.
    func surfaceClearCheckingMarksInCode(in range: NSRange) {}
    /// Files are not watched yet on iOS; the document system reloads the
    /// document itself.
    func surfaceWatchImages(_ urls: Set<URL>) {}
}

// MARK: - Edits

extension MobileTextView: NSTextStorageDelegate {
    /// Every change to the characters reaches the styler here, so the
    /// restyle after it can stay local to the edit.
    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorage.EditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            syntaxStyler.noteEdit(editedRange, delta: delta)
        }
    }
}
