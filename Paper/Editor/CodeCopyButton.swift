import AppKit

/// The copy control in a fenced code block's top-right corner. One sits
/// over each visible band, invisible until the pointer is over the band,
/// when it fades in; a click puts the block's content on the pasteboard
/// and shows a check for a moment. The view covers the whole band so the
/// hover works anywhere in it, but only the icon takes clicks: everywhere
/// else the press falls through to the text.
@MainActor
final class CodeCopyButton: NSView {
    /// The block's paragraph range (fences included) as of the last sync.
    var blockRange = NSRange()
    /// Where the copied text goes; tests substitute their own.
    var pasteboard: NSPasteboard = .general

    static let iconSize: CGFloat = 13
    /// Room around the icon: the band's own content inset, so the icon
    /// sits where the first character would.
    static var inset: CGFloat { Appearance.codeBlockInset }
    static let fadeIn: TimeInterval = 0.18
    static let fadeOut: TimeInterval = 0.28
    static let shrink: TimeInterval = 0.12
    static let checkDwell: TimeInterval = 1.4

    private let icon = CodeCopyIcon(frame: .zero)
    private var checkTimer: Timer?
    /// True while the check is shown or on its way in.
    private(set) var showingCheck = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        addSubview(icon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// The icon's square in the top-right corner, the band's content
    /// inset from both edges.
    var iconRect: NSRect {
        NSRect(
            x: bounds.width - Self.inset - Self.iconSize,
            y: Self.inset,
            width: Self.iconSize,
            height: Self.iconSize
        )
    }

    /// The click target: the icon padded by half the inset each way.
    var hitRect: NSRect { iconRect.insetBy(dx: -Self.inset * 0.5, dy: -Self.inset * 0.5) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        icon.frame = iconRect
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    private var hovering = false

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        fade(to: 1, over: Self.fadeIn)
    }

    /// Leaving the band hides the icon, unless it is showing the check:
    /// that stays for its moment and fades once it has turned back.
    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !showingCheck { fade(to: 0, over: Self.fadeOut) }
    }

    private func fade(to alpha: CGFloat, over duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = alpha
        }
    }

    /// True when `point` (in the text view's coordinates) is on the icon;
    /// the text view shows the hand there instead of its I-beam.
    func isOnIcon(_ point: NSPoint) -> Bool {
        hitRect.contains(convert(point, from: superview))
    }

    // MARK: - Click

    /// Only the icon is this view's: a press anywhere else in the band
    /// goes to the text under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return hitRect.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        copyBlock()
    }

    /// Copies the lines between the fences, then the copy glyph shrinks
    /// away and the check springs in; after a moment they trade back.
    func copyBlock() {
        guard let textView = superview as? NSTextView else { return }
        let content = CodeBlockCopy.content(of: blockRange, in: textView.string)
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        showingCheck = true
        icon.morph(to: .check)
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: Self.checkDwell, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.showingCheck = false
                self.icon.morph(to: .copy)
                if !self.hovering { self.fade(to: 0, over: Self.fadeOut) }
            }
        }
    }

    // MARK: - Drawing

    /// A backing in the band's own colour under the icon, so a long line
    /// running beneath it does not show through.
    override func draw(_ dirtyRect: NSRect) {
        let backing = NSBezierPath(
            roundedRect: hitRect,
            xRadius: Appearance.codeChipCornerRadius, yRadius: Appearance.codeChipCornerRadius
        )
        Appearance.canvas.setFill()
        backing.fill()
        Appearance.codeBlockBackground.setFill()
        backing.fill()
        icon.needsDisplay = true
    }
}

/// The glyph itself, a layer-backed square that scales about its centre:
/// out to nothing, then in with a spring, when it changes shape.
@MainActor
final class CodeCopyIcon: NSView {
    enum Shape { case copy, check }
    private(set) var shape: Shape = .copy

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// A view layer's anchor is its origin and AppKit keeps it there, so
    /// scaling about the centre is written into the transform itself.
    private func scaled(_ scale: CGFloat) -> CATransform3D {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        var transform = CATransform3DMakeTranslation(centre.x, centre.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -centre.x, -centre.y, 0)
    }

    func morph(to next: Shape) {
        guard next != shape else { return }
        guard let layer, window != nil else {
            shape = next
            needsDisplay = true
            return
        }
        let out = CABasicAnimation(keyPath: "transform")
        out.fromValue = NSValue(caTransform3D: scaled(1))
        out.toValue = NSValue(caTransform3D: scaled(0.001))
        out.duration = CodeCopyButton.shrink
        out.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let layer = self.layer else { return }
                self.shape = next
                self.displayIfNeeded()
                self.needsDisplay = true
                self.displayIfNeeded()
                let spring = CASpringAnimation(keyPath: "transform")
                spring.fromValue = NSValue(caTransform3D: self.scaled(0.001))
                spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                spring.damping = 18
                spring.stiffness = 300
                spring.mass = 0.9
                spring.initialVelocity = 2
                spring.duration = spring.settlingDuration
                layer.transform = CATransform3DIdentity
                layer.add(spring, forKey: "scale")
            }
        }
        layer.transform = scaled(0.001)
        layer.add(out, forKey: "scale")
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let ink = Appearance.ink.withAlphaComponent(0.6)
        ink.setFill()
        ink.setStroke()
        switch shape {
        case .copy: Self.drawCopyGlyph(in: bounds)
        case .check: Self.checkPath(in: bounds).stroke()
        }
    }

    /// Two sheets, the front one lower-right: the outline of each is a
    /// 1.5-unit ring in a 16-unit square scaled to `rect`, and the back
    /// sheet stops where the front one covers it.
    static func drawCopyGlyph(in rect: NSRect) {
        let scale = rect.width / 16
        var transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
        transform.scale(scale)
        func ring(_ outer: NSRect) -> NSBezierPath {
            let path = NSBezierPath(roundedRect: outer, xRadius: 1.75, yRadius: 1.75)
            path.append(NSBezierPath(roundedRect: outer.insetBy(dx: 1.5, dy: 1.5), xRadius: 0.25, yRadius: 0.25))
            path.windingRule = .evenOdd
            path.transform(using: transform)
            return path
        }
        NSGraphicsContext.saveGraphicsState()
        // Everything right of x 4.5 and below y 3 lies under the front sheet.
        let keep = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 16, height: 16))
        keep.append(NSBezierPath(rect: NSRect(x: 4.5, y: 3, width: 12, height: 13)))
        keep.windingRule = .evenOdd
        keep.transform(using: transform)
        keep.addClip()
        ring(NSRect(x: 1, y: 0.5, width: 9, height: 11)).fill()
        NSGraphicsContext.restoreGraphicsState()
        ring(NSRect(x: 6, y: 4.5, width: 9, height: 11)).fill()
    }

    static func checkPath(in rect: NSRect) -> NSBezierPath {
        let scale = rect.width / 16
        let path = NSBezierPath()
        path.lineWidth = 1.8 * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: rect.minX + 2.5 * scale, y: rect.minY + 8.5 * scale))
        path.line(to: NSPoint(x: rect.minX + 6.5 * scale, y: rect.minY + 12.5 * scale))
        path.line(to: NSPoint(x: rect.minX + 13.5 * scale, y: rect.minY + 4 * scale))
        return path
    }
}

/// What a copy of a fenced block puts on the pasteboard.
enum CodeBlockCopy {
    /// The lines between the fences of the block whose paragraph range is
    /// `block`: no fence lines, no info string, interior blank lines kept,
    /// and no newline after the last line.
    static func content(of block: NSRange, in source: String) -> String {
        let text = source as NSString
        guard block.length > 0, NSMaxRange(block) <= text.length else { return "" }
        let opening = text.paragraphRange(for: NSRange(location: block.location, length: 0))
        let closing = text.paragraphRange(for: NSRange(location: NSMaxRange(block) - 1, length: 0))
        guard closing.location > NSMaxRange(opening) else { return "" }
        var content = text.substring(with: NSRange(location: NSMaxRange(opening), length: closing.location - NSMaxRange(opening)))
        while content.hasSuffix("\n") || content.hasSuffix("\r") { content.removeLast() }
        return content
    }
}

extension PaperTextView {
    /// Puts one `CodeCopyButton` over each code band in the viewport and
    /// drops the rest. Called from drawing, after layout has settled, and
    /// only mutates the view tree when a band has appeared, moved, or gone.
    func syncCodeCopyButtons() {
        // A print or PDF pass draws subviews whatever their alpha, and the
        // button is chrome, not document: none is made or shown for it.
        if NSPrintOperation.current != nil {
            for button in codeCopyButtons { button.isHidden = true }
            return
        }
        for button in codeCopyButtons { button.isHidden = false }
        guard let layoutManager = layoutManager as? PaperLayoutManager,
              let container = textContainer else { return }
        let origin = textContainerOrigin
        let visible = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let blocks = layoutManager.codeBlocks(forGlyphRange: glyphRange)

        let frames = blocks.map { block in
            NSRect(x: origin.x, y: origin.y + block.rect.minY, width: container.size.width, height: block.rect.height)
        }
        while codeCopyButtons.count > blocks.count {
            codeCopyButtons.removeLast().removeFromSuperview()
        }
        while codeCopyButtons.count < blocks.count {
            let button = CodeCopyButton(frame: .zero)
            addSubview(button)
            codeCopyButtons.append(button)
        }
        for (button, (block, frame)) in zip(codeCopyButtons, zip(blocks, frames)) {
            if button.frame != frame { button.frame = frame }
            button.blockRange = block.range
            button.needsDisplay = true
        }
    }
}
