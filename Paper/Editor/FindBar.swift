import AppKit

/// Find (#21): a small pill at the top right of the window, in the zoom
/// badge's style, with a field and a count. Typing moves the selection to
/// the next match from the caret and tints every match; Return and
/// ⇧Return step; Esc closes and leaves the selection on the match. Find
/// runs over the source, concealed syntax included, since that is what
/// editing operates on. No replace in this cut.
///
/// The scroll view owns the pill and answers the Edit ▸ Find items: the
/// responder chain from the pill's field runs through the scroll view and
/// not the text view, and ⌘G while typing a search has to work.
final class PaperScrollView: NSScrollView {
    private(set) var pill: FindPill?
    private var query = ""
    private var matches: [NSRange] = []
    private var textObserver: NSObjectProtocol?

    private var textView: NSTextView? { documentView as? NSTextView }

    /// The wide scroller with a track under it, kept whatever the input
    /// device. AppKit re-applies the system's preferred style to every
    /// scroll view when a mouse comes or goes, through this same setter,
    /// so the choice is made here rather than once at setup.
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .legacy }
    }

    // MARK: - Actions (Edit ▸ Find)

    /// ⌘F: open the pill, seeded with a short single-line selection, and
    /// put the caret in its field with the query selected.
    @objc func showFind(_ sender: Any?) {
        if let seed = selectionSeed() { query = seed }
        openPill()
        refresh(select: .none)
        pill?.focus()
    }

    @objc func findNext(_ sender: Any?) { step(forward: true) }
    @objc func findPrevious(_ sender: Any?) { step(forward: false) }

    /// Sets the query from the selection without opening the pill; ⌘G
    /// then walks the matches.
    @objc func useSelectionForFind(_ sender: Any?) {
        guard let seed = selectionSeed() else { return }
        query = seed
        pill?.query = seed
        refresh(select: .none)
    }

    override var backgroundColor: NSColor {
        didSet { pill?.restyle() }
    }

    override func tile() {
        super.tile()
        pill?.place()
    }

    // MARK: - The pill

    private func openPill() {
        if pill == nil {
            let pill = FindPill()
            pill.onChange = { [weak self] text in self?.queryChanged(text) }
            pill.onStep = { [weak self] forward in self?.step(forward: forward) }
            pill.onClose = { [weak self] in self?.closeFind() }
            addSubview(pill, positioned: .above, relativeTo: nil)
            self.pill = pill
            if let textView {
                textObserver = NotificationCenter.default.addObserver(
                    forName: NSText.didChangeNotification, object: textView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh(select: .none) }
                }
            }
        }
        pill?.query = query
        pill?.place()
        pill?.appear()
    }

    /// Esc, or the field losing the query: the tint goes, the selection
    /// stays where find left it, the text view takes the keys back.
    func closeFind() {
        guard let pill else { return }
        pill.dismiss()
        self.pill = nil
        if let textObserver { NotificationCenter.default.removeObserver(textObserver) }
        textObserver = nil
        matches = []
        clearTint()
        if let textView, let window { window.makeFirstResponder(textView) }
    }

    private func queryChanged(_ text: String) {
        query = text
        refresh(select: .nextFromCaret)
    }

    // MARK: - Matching

    private enum Selection { case none, nextFromCaret }

    /// Recomputes the matches for the query, tints them, updates the count,
    /// and optionally moves the selection to the first match at or after
    /// the caret (the incremental step as the query grows).
    private func refresh(select: Selection) {
        guard let textView else { return }
        let text = textView.string as NSString
        matches = FindSession.matches(of: query, in: text)
        clearTint()
        tint()
        if select == .nextFromCaret, let index = FindSession.next(from: textView.selectedRange(), in: matches) {
            show(matches[index])
        }
        updateCount()
    }

    private func step(forward: Bool) {
        guard !query.isEmpty else { showFind(nil); return }
        guard let textView else { return }
        if matches.isEmpty { refresh(select: .none) }
        let selection = textView.selectedRange()
        let index = forward
            ? FindSession.next(from: selection, in: matches, after: selection.length > 0)
            : FindSession.previous(from: selection, in: matches)
        guard let index else { NSSound.beep(); return }
        show(matches[index])
        updateCount()
    }

    private func show(_ range: NSRange) {
        guard let textView else { return }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    private func updateCount() {
        guard let pill else { return }
        if query.isEmpty { pill.count = ""; return }
        guard !matches.isEmpty else { pill.count = "0"; return }
        let selection = textView?.selectedRange()
        if let selection, let index = matches.firstIndex(where: { NSEqualRanges($0, selection) }) {
            pill.count = "\(index + 1) of \(matches.count)"
        } else {
            pill.count = "\(matches.count)"
        }
    }

    private func tint() {
        guard let layoutManager = textView?.layoutManager else { return }
        for match in matches {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: Appearance.selection, forCharacterRange: match)
        }
    }

    private func clearTint() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let whole = NSRange(location: 0, length: (textView.string as NSString).length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
    }

    /// A selection worth searching for: one line, not long, not empty.
    private func selectionSeed() -> String? {
        guard let textView else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0, range.length <= 200 else { return nil }
        let text = (textView.string as NSString).substring(with: range)
        guard !text.contains("\n"), !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }
}

/// The search over the source: literal, case-insensitive, non-overlapping.
enum FindSession {
    static func matches(of query: String, in text: NSString) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        var found: [NSRange] = []
        var cursor = 0
        while cursor < text.length {
            let range = text.range(of: query, options: [.caseInsensitive], range: NSRange(location: cursor, length: text.length - cursor))
            guard range.location != NSNotFound else { break }
            found.append(range)
            cursor = range.location + max(range.length, 1)
        }
        return found
    }

    /// The first match at or after the selection, wrapping to the top;
    /// `after` skips a match the selection already covers, so ⌘G on a
    /// found match moves on.
    static func next(from selection: NSRange, in matches: [NSRange], after: Bool = false) -> Int? {
        guard !matches.isEmpty else { return nil }
        let threshold = after ? selection.location + max(selection.length, 1) : selection.location
        return matches.firstIndex { $0.location >= threshold } ?? 0
    }

    /// The last match before the selection, wrapping to the bottom.
    static func previous(from selection: NSRange, in matches: [NSRange]) -> Int? {
        guard !matches.isEmpty else { return nil }
        return matches.lastIndex { $0.location < selection.location } ?? matches.count - 1
    }
}

/// The capsule: a field and a count, the zoom badge's size and colours.
final class FindPill: NSView, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    var onStep: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let label = NSTextField(labelWithString: "")

    static let fieldWidth: CGFloat = 150
    static let horizontal: CGFloat = 9
    static let vertical: CGFloat = 4
    static let gap: CGFloat = 8
    static let margin = NSEdgeInsets(top: 14, left: 16, bottom: 0, right: 16)

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    var count: String = "" {
        didSet {
            label.stringValue = count
            label.isHidden = count.isEmpty
            place()
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.minXMargin, .maxYMargin]

        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Find"
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        addSubview(field)

        label.alignment = .right
        label.isHidden = true
        addSubview(label)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static var font: NSFont {
        let base = NSFont.systemFont(ofSize: 12, weight: .medium)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return NSFont(descriptor: descriptor, size: 12) ?? base
    }

    func restyle() {
        for control in [field, label] {
            control.font = Self.font
            control.textColor = Appearance.labelInk
        }
        field.placeholderAttributedString = NSAttributedString(
            string: "Find",
            attributes: [.font: Self.font, .foregroundColor: Appearance.mutedInk]
        )
        needsDisplay = true
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Top-right corner of the superview, sized to the field, the count,
    /// and the padding.
    func place() {
        guard let superview else { return }
        label.sizeToFit()
        let lineHeight = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        let height = lineHeight + Self.vertical * 2
        let countWidth = label.isHidden ? 0 : label.frame.width + Self.gap
        let width = Self.horizontal * 2 + Self.fieldWidth + countWidth
        // The scroll view is flipped, so the top is the origin.
        let y = superview.isFlipped
            ? superview.bounds.minY + Self.margin.top
            : superview.bounds.maxY - Self.margin.top - height
        frame = NSRect(
            x: superview.bounds.maxX - Self.margin.right - width,
            y: y,
            width: width,
            height: height
        )
        field.frame = NSRect(x: Self.horizontal, y: Self.vertical, width: Self.fieldWidth, height: lineHeight)
        label.frame = NSRect(x: Self.horizontal + Self.fieldWidth + Self.gap, y: Self.vertical, width: label.frame.width, height: lineHeight)
    }

    /// Grows in from the corner with a fade; a short ease-out so the field
    /// is ready by the time the first letter is typed.
    func appear() {
        guard let layer, superview != nil else { return }
        layer.anchorPoint = CGPoint(x: 1, y: superview?.isFlipped == true ? 0 : 1)
        layer.position = CGPoint(x: frame.maxX, y: superview?.isFlipped == true ? frame.minY : frame.maxY)
        let group = CAAnimationGroup()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.85
        grow.toValue = 1
        group.animations = [fade, grow]
        group.duration = 0.2
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "appear")
    }

    /// Fades out, then leaves the view tree.
    func dismiss() {
        guard let layer, window != nil else { removeFromSuperview(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.12
        fade.isRemovedOnCompletion = false
        fade.fillMode = .forwards
        layer.add(fade, forKey: "dismiss")
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        Appearance.codeBlockBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            onStep?(!shift)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        case #selector(NSResponder.moveDown(_:)):
            onStep?(true)
            return true
        case #selector(NSResponder.moveUp(_:)):
            onStep?(false)
            return true
        default:
            return false
        }
    }
}
