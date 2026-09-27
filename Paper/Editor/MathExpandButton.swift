import AppKit

/// The expand control in a display-math block's top-right corner, where a
/// code block keeps its copy control. One sits over each visible block, invisible until the pointer is over it, when
/// it fades in; a click opens the formula enlarged in Quick Look. As with
/// the code copy button, the view covers the whole figure so the hover
/// works anywhere on it, but only the icon takes clicks.
@MainActor
final class MathExpandButton: NSView {
    /// The formula's LaTeX as of the last sync.
    var latex = ""
    /// The icon's square, in this view's coordinates.
    var iconRect = NSRect.zero {
        didSet { needsDisplay = true }
    }

    static let iconSize: CGFloat = 13
    static let fadeIn: TimeInterval = 0.18
    static let fadeOut: TimeInterval = 0.28

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// The click target: the icon padded a little each way.
    var hitRect: NSRect { iconRect.insetBy(dx: -6, dy: -6) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { fade(to: 1, over: Self.fadeIn) }
    override func mouseExited(with event: NSEvent) { fade(to: 0, over: Self.fadeOut) }

    private func fade(to alpha: CGFloat, over duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = alpha
        }
    }

    /// True when `point` (in the text view's coordinates) is on the icon.
    func isOnIcon(_ point: NSPoint) -> Bool {
        hitRect.contains(convert(point, from: superview))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        hitRect.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView = superview as? PaperTextView,
              let url = MathStore.shared.previewFile(for: latex) else { return }
        textView.preview(url)
    }

    /// Two arrows out to opposite corners, fainter than the code copy icon:
    /// the formula is the figure and the control should not compete with
    /// it. A canvas backing keeps anything beneath from showing through.
    override func draw(_ dirtyRect: NSRect) {
        Appearance.canvas.setFill()
        NSBezierPath(roundedRect: hitRect, xRadius: Appearance.codeChipCornerRadius, yRadius: Appearance.codeChipCornerRadius).fill()
        let ink = Appearance.ink.withAlphaComponent(0.35)
        ink.setStroke()
        Self.expandPath(in: iconRect).stroke()
    }

    /// Diagonal arrows to the top-right and bottom-left corners of a
    /// 16-unit square scaled to `rect` (flipped: y grows downward).
    static func expandPath(in rect: NSRect) -> NSBezierPath {
        let scale = rect.width / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        let path = NSBezierPath()
        path.lineWidth = 1.6 * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        // Top right: the head, then the shaft in toward the centre.
        path.move(to: point(9.5, 1.5)); path.line(to: point(14.5, 1.5)); path.line(to: point(14.5, 6.5))
        path.move(to: point(14.5, 1.5)); path.line(to: point(9.5, 6.5))
        // Bottom left, mirrored.
        path.move(to: point(1.5, 9.5)); path.line(to: point(1.5, 14.5)); path.line(to: point(6.5, 14.5))
        path.move(to: point(1.5, 14.5)); path.line(to: point(6.5, 9.5))
        return path
    }
}

extension PaperTextView {
    /// Every display formula on the page that parses, in document order, in
    /// view coordinates: `block` spans the source rows and the band, `area`
    /// is where the formula is centred (the block off the active paragraph,
    /// the band alone on it), `formula` the rect it draws in.
    func mathFigures(in glyphRange: NSRange? = nil) -> [(block: NSRect, area: NSRect, formula: NSRect, latex: String)] {
        guard let layoutManager = layoutManager as? PaperLayoutManager,
              let container = textContainer else { return [] }
        let origin = textContainerOrigin
        let width = MarkdownSyntaxStyler.measure(of: self)
        let glyphs = glyphRange ?? layoutManager.glyphRange(for: container)
        return layoutManager.mathBands(forGlyphRange: glyphs, width: width).compactMap { math in
            guard case .success(let formula) = MathStore.shared.display(math.latex) else { return nil }
            let area = (math.active ? math.band : math.block).offsetBy(dx: origin.x, dy: origin.y)
            let size = formula.fitted(to: width)
            let rect = NSRect(
                x: (area.midX - size.width / 2).rounded(),
                y: (area.midY - size.height / 2).rounded(),
                width: size.width, height: size.height
            )
            return (math.block.offsetBy(dx: origin.x, dy: origin.y), area, rect, math.latex)
        }
    }

    /// Puts one `MathExpandButton` over each math block in the viewport, its
    /// icon in the block's top-right corner at the code band's inset, and
    /// drops the rest. The block, not the formula, anchors it, so the icon
    /// stays put when the caret reveals the source. Called from drawing,
    /// like `syncCodeCopyButtons`.
    func syncMathExpandButtons() {
        if NSPrintOperation.current != nil {
            for button in mathExpandButtons { button.isHidden = true }
            return
        }
        for button in mathExpandButtons { button.isHidden = false }
        guard let layoutManager = layoutManager as? PaperLayoutManager,
              let container = textContainer else { return }
        let origin = textContainerOrigin
        let visible = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let figures = mathFigures(in: layoutManager.glyphRange(forBoundingRect: visible, in: container))

        while mathExpandButtons.count > figures.count {
            mathExpandButtons.removeLast().removeFromSuperview()
        }
        while mathExpandButtons.count < figures.count {
            let button = MathExpandButton(frame: .zero)
            addSubview(button)
            mathExpandButtons.append(button)
        }
        let size = MathExpandButton.iconSize
        let inset = Appearance.codeBlockInset
        for (button, figure) in zip(mathExpandButtons, figures) {
            if button.frame != figure.block { button.frame = figure.block }
            button.iconRect = NSRect(x: figure.block.width - inset - size, y: inset, width: size, height: size)
            button.latex = figure.latex
        }
    }
}
