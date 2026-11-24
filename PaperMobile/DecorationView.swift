import UIKit

/// Draws the page under the text: code block bands, quote rules, thematic
/// breaks, table cells and rules, task circles, block images, and display
/// and inline math. The Mac draws the same things in `PaperTextView`'s
/// `drawBackground(in:)`; the geometry comes from the shared
/// `PaperLayoutManager` on both.
///
/// The view sits behind the text view's text, over a band around the
/// viewport (see `MobileTextView.placeDecorations`). Its own coordinates
/// are translated to the text view's content coordinates before drawing,
/// so the code reads like the Mac's: both are top-left origin.
///
/// This is the reader's copy of the Mac's drawing (IOS-03). A shared
/// renderer replaces both copies once the approach is proven (IOS-06).
final class DecorationView: UIView {
    weak var textView: MobileTextView?

    override func draw(_ rect: CGRect) {
        guard let textView, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.translateBy(x: -frame.minX, y: -frame.minY)
        let dirty = rect.offsetBy(dx: frame.minX, dy: frame.minY)
        let page = PageGeometry(textView: textView, dirty: dirty)
        drawCodeBlockBands(page)
        drawQuoteRules(page)
        drawThematicBreaks(page)
        drawTables(page)
        drawTaskCircles(page)
        drawImages(page, context: context)
        drawMath(page)
        drawInlineMath(page)
        context.restoreGState()
    }

    /// What every pass needs: the layout, the container's origin in the
    /// view, and the glyphs under the dirty rect.
    private struct PageGeometry {
        let layoutManager: PaperLayoutManager
        let container: NSTextContainer
        let storage: NSTextStorage
        let origin: CGPoint
        let dirty: CGRect
        let glyphRange: NSRange
        let measure: CGFloat

        @MainActor
        init(textView: MobileTextView, dirty: CGRect) {
            layoutManager = textView.paperLayoutManager
            container = textView.textContainer
            storage = textView.textStorage
            origin = textView.textContainerOrigin
            self.dirty = dirty
            glyphRange = layoutManager.glyphRange(
                forBoundingRect: dirty.offsetBy(dx: -origin.x, dy: -origin.y), in: container
            )
            measure = MarkdownSyntaxStyler.measure(of: textView)
        }
    }

    private func drawCodeBlockBands(_ page: PageGeometry) {
        let rects = page.layoutManager.codeBlockRects(forGlyphRange: page.glyphRange)
        guard !rects.isEmpty else { return }
        Appearance.codeBlockBackground.setFill()
        for rect in rects {
            UIBezierPath(
                roundedRect: CGRect(
                    x: page.origin.x, y: page.origin.y + rect.minY,
                    width: page.container.size.width, height: rect.height
                ),
                cornerRadius: Appearance.codeBlockCornerRadius
            ).fill()
        }
    }

    private func drawQuoteRules(_ page: PageGeometry) {
        let rects = page.layoutManager.quoteRuleRects(forGlyphRange: page.glyphRange)
        guard !rects.isEmpty else { return }
        Appearance.mutedInk.setFill()
        for rect in rects {
            let rule = CGRect(
                x: page.origin.x + page.container.lineFragmentPadding, y: page.origin.y + rect.minY,
                width: Appearance.quoteRuleWidth, height: rect.height
            )
            UIBezierPath(roundedRect: rule, cornerRadius: Appearance.quoteRuleWidth / 2).fill()
        }
    }

    private func drawThematicBreaks(_ page: PageGeometry) {
        let rects = page.layoutManager.thematicBreakRects(forGlyphRange: page.glyphRange)
        guard !rects.isEmpty else { return }
        Appearance.thematicBreakInk.setFill()
        let padding = page.container.lineFragmentPadding
        for fragment in rects {
            UIBezierPath(rect: CGRect(
                x: page.origin.x + padding,
                y: page.origin.y + fragment.midY - Appearance.thematicBreakThickness / 2,
                width: page.container.size.width - 2 * padding,
                height: Appearance.thematicBreakThickness
            )).fill()
        }
    }

    private func drawTables(_ page: PageGeometry) {
        let left = page.origin.x + page.container.lineFragmentPadding
        let thickness = Appearance.thematicBreakThickness
        for row in page.layoutManager.tableRows(forGlyphRange: page.glyphRange) {
            let layout = row.mark.layout
            let top = page.origin.y + row.top
            let bottom = page.origin.y + row.bottom
            switch row.mark.kind {
            case .delimiter:
                guard !row.active else { continue }
                Appearance.tableHeaderRuleInk.setFill()
                UIBezierPath(rect: CGRect(x: left, y: top, width: layout.width, height: thickness)).fill()
            case .header, .body:
                if row.mark.kind == .body, row.mark.row < layout.rows.count - 1 {
                    Appearance.tableRowRuleInk.setFill()
                    UIBezierPath(rect: CGRect(x: left, y: bottom - thickness, width: layout.width, height: thickness)).fill()
                }
                guard !row.active, row.mark.row < layout.rows.count else { continue }
                for (index, cell) in layout.rows[row.mark.row].enumerated() where index < layout.columns.count {
                    let column = layout.columns[index]
                    TableMeasure.draw(cell.text, in: CGRect(
                        x: left + column.x, y: top + layout.padding,
                        width: column.width, height: max(bottom - top - layout.padding, 0)
                    ))
                }
            }
        }
    }

    private func drawTaskCircles(_ page: PageGeometry) {
        guard page.storage.length > 0 else { return }
        let characters = page.layoutManager.characterRange(forGlyphRange: page.glyphRange, actualGlyphRange: nil)
        let text = page.storage.string as NSString
        page.storage.enumerateAttribute(.taskBox, in: characters) { value, run, _ in
            guard let box = value as? String, let rect = taskCircleRect(forPrefix: run, page: page) else { return }
            let circle = rect.offsetBy(dx: page.origin.x, dy: page.origin.y)
            let nested = run.location > 0 && [0x20, 0x09].contains(text.character(at: run.location - 1))
            let shape: (CGRect) -> UIBezierPath = { rect in
                nested ? UIBezierPath(roundedRect: rect, cornerRadius: rect.width * 0.28) : UIBezierPath(ovalIn: rect)
            }
            guard box != "[ ]" else {
                let ring = shape(circle.insetBy(dx: Appearance.taskBoxStroke / 2, dy: Appearance.taskBoxStroke / 2))
                ring.lineWidth = Appearance.taskBoxStroke
                Appearance.thematicBreakInk.setStroke()
                ring.stroke()
                return
            }
            Appearance.ink.setFill()
            shape(circle).fill()
            let side = circle.width * 0.56
            let target = CGRect(
                x: circle.midX - side / 2, y: circle.midY - side / 2 - circle.width * 0.02,
                width: side, height: side
            )
            UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .bold))?
                .withTintColor(Appearance.canvas, renderingMode: .alwaysOriginal)
                .draw(in: target)
        }
    }

    private func taskCircleRect(forPrefix prefix: NSRange, page: PageGeometry) -> CGRect? {
        Self.taskCircleRect(forPrefix: prefix, layoutManager: page.layoutManager, storage: page.storage)
    }

    /// The circle in the room a task item's concealed `[ ]` reserves, in
    /// container coordinates, centred on the cap height of the text beside
    /// it. Taps use the same rect.
    static func taskCircleRect(forPrefix prefix: NSRange, layoutManager: PaperLayoutManager, storage: NSTextStorage) -> CGRect? {
        guard prefix.length >= 3, layoutManager.isConcealed(characterAt: NSMaxRange(prefix) - 1) else { return nil }
        let index = NSMaxRange(prefix) - 3
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
        let location = layoutManager.location(forGlyphAt: glyph)
        let font = storage.attribute(.font, at: index, effectiveRange: nil) as? UIFont ?? Appearance.bodyFont()
        let size = Appearance.taskBoxSize
        return CGRect(
            x: fragment.minX + location.x,
            y: fragment.minY + location.y - font.capHeight / 2 - size / 2,
            width: size, height: size
        )
    }

    private func drawImages(_ page: PageGeometry, context: CGContext) {
        for band in page.layoutManager.imageBands(forGlyphRange: page.glyphRange, width: page.measure) {
            let placed = band.rect.offsetBy(dx: page.origin.x, dy: page.origin.y)
            guard placed.intersects(page.dirty) else { continue }
            let outline = UIBezierPath(roundedRect: placed, cornerRadius: Appearance.imageCornerRadius)
            // Drawing only looks in the cache; demand decodes. Until the
            // bitmap lands the band is a quiet panel the image's size.
            guard let entry = ImageStore.shared.residentImage(for: band.url) else {
                Appearance.codeBlockBackground.setFill()
                outline.fill()
                continue
            }
            context.saveGState()
            outline.addClip()
            context.interpolationQuality = .high
            entry.image.draw(in: placed)
            context.restoreGState()
        }
    }

    private func drawMath(_ page: PageGeometry) {
        for math in page.layoutManager.mathBands(forGlyphRange: page.glyphRange, width: page.measure) {
            switch MathStore.shared.display(math.latex) {
            case .success(let formula):
                let area = (math.active ? math.band : math.block).offsetBy(dx: page.origin.x, dy: page.origin.y)
                guard area.intersects(page.dirty) else { continue }
                let size = formula.fitted(to: page.measure)
                formula.draw(in: CGRect(
                    x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                    width: size.width, height: size.height
                ), color: Appearance.mathInk)
            case .failure(let failure):
                let band = math.band.offsetBy(dx: page.origin.x, dy: page.origin.y)
                guard band.intersects(page.dirty) else { continue }
                NSAttributedString(string: failure.message, attributes: [
                    .font: Appearance.codeFont(),
                    .foregroundColor: Appearance.mutedInk,
                ]).draw(at: CGPoint(x: band.minX, y: band.minY + Appearance.mathBandPadding / 2))
            }
        }
    }

    private func drawInlineMath(_ page: PageGeometry) {
        for inline in page.layoutManager.inlineFormulas(forGlyphRange: page.glyphRange) {
            let rect = inline.rect.offsetBy(dx: page.origin.x, dy: page.origin.y)
            guard rect.intersects(page.dirty),
                  case .success(let formula) = MathStore.shared.typeset(inline.math.latex, style: .inline, size: inline.math.size)
            else { continue }
            formula.draw(in: rect, color: inline.math.color)
        }
    }
}
