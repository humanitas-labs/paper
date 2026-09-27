import AppKit
import Testing
@testable import Paper

/// Inline math: `$…$` in a line draws as the typeset formula in the width
/// its concealed source reserves, on the text's baseline. Prices and paths
/// stay prose, code spans win, the source is never edited, and a formula
/// taller than the line makes the paragraph's lines taller in both states.
@MainActor
struct InlineMathTests {
    private func styledView(_ text: String, width: CGFloat = 800) -> PaperTextView {
        let textView = PaperTextView()
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        textView.string = text
        textView.syntaxStyler.apply(to: textView)
        return textView
    }

    private func spans(_ source: String) -> [String] {
        let range = NSRange(location: 0, length: source.utf16.count)
        let fenced = MarkdownSyntaxStyler.fencedBlocks(in: source, range: range)
        let display = MarkdownSyntaxStyler.mathBlocks(in: source, range: range, fenced: fenced, comments: []).map(\.range)
        return MarkdownSyntaxStyler.inlineMathSpans(in: source, range: range, excluding: fenced + display).map(\.latex)
    }

    // MARK: Recognition

    @Test
    func formulasAreRecognisedBetweenDollars() {
        #expect(spans("Einstein wrote $E = mc^2$ in 1905.") == ["E = mc^2"])
        #expect(spans("$x$ and $y$") == ["x", "y"])
        #expect(spans("($x$)") == ["x"], "punctuation either side")
        #expect(spans("a $\\$5$ b") == ["\\$5"], "an escaped dollar inside")
        #expect(spans("it costs $5 and $x$ here") == ["x"])
    }

    @Test
    func pricesPathsAndEscapesStayProse() {
        #expect(spans("$5 and $10").isEmpty)
        #expect(spans("It costs $5.").isEmpty)
        #expect(spans("$HOME/bin").isEmpty)
        #expect(spans("\\$x\\$").isEmpty, "escaped dollars")
        #expect(spans("$ x $").isEmpty, "space inside the dollars")
        #expect(spans("$x$5").isEmpty, "a digit after the closer")
        #expect(spans("between $5 and$6").isEmpty)
        #expect(spans("$$x$$").isEmpty, "display syntax")
        #expect(spans("$a\nb$").isEmpty, "never across lines")
    }

    @Test
    func codeFencesAndDisplayMathWin() {
        #expect(spans("`$x$` in code").isEmpty)
        #expect(spans("$a `b$ c`").isEmpty, "overlapping a code span")
        #expect(spans("```\n$x$\n```\n").isEmpty)
        #expect(spans("$$\na $b$ c\n$$\n").isEmpty)
    }

    @Test
    func stylingLeavesTheSourceUnchanged() {
        let source = "A $\\frac{a}{b}$ and $x_1 * y$ line.\n\nPrices: $5 and $10.\n"
        #expect(styledView(source).string == source)
    }

    // MARK: Attributes

    @Test
    func aFormulaReservesItsWidthAndConceals() throws {
        let textView = styledView("A $x^2 + y^2$ line.")
        let storage = try #require(textView.textStorage)
        let text = textView.string as NSString
        let span = text.range(of: "$x^2 + y^2$")
        let math = try #require(storage.attribute(.inlineMath, at: span.location, effectiveRange: nil) as? InlineMath)
        guard case .success(let formula) = MathStore.shared.typeset("x^2 + y^2", style: .inline, size: math.size) else {
            Issue.record("expected a formula")
            return
        }
        #expect(storage.attribute(.reservedWidth, at: span.location, effectiveRange: nil) as? CGFloat == formula.width)
        for index in span.location..<NSMaxRange(span) {
            #expect(storage.attribute(.concealable, at: index, effectiveRange: nil) != nil)
        }
        #expect(storage.attribute(.inlineMath, at: text.range(of: "line").location, effectiveRange: nil) == nil)
        #expect(math.size >= Appearance.bodySize, "never smaller than the text")
    }

    @Test
    func sourceThatDoesNotParseStaysVisible() throws {
        let textView = styledView("A $\\frac{a}{$ line.")
        let storage = try #require(textView.textStorage)
        #expect(storage.attribute(.concealable, at: 3, effectiveRange: nil) == nil)
        #expect(storage.attribute(.reservedWidth, at: 2, effectiveRange: nil) == nil)
        #expect(storage.attribute(.toolTip, at: 3, effectiveRange: nil) is String, "the error is the tooltip")
        #expect(textView.touchesCode(NSRange(location: 3, length: 4)), "still math, so not spell-checked")
    }

    @Test
    func mathIsNotCheckedAsProse() {
        let textView = styledView("Take $\\alpha + \\beta$ here.")
        #expect(textView.touchesCode(NSRange(location: 7, length: 5)))
        #expect(!textView.touchesCode(NSRange(location: 0, length: 4)))
    }

    @Test
    func emphasisDoesNotReachIntoMath() throws {
        let textView = styledView("Then $a_1 * b_2 * c$ holds.")
        let storage = try #require(textView.textStorage)
        let star = (textView.string as NSString).range(of: "*").location
        #expect(storage.attribute(.font, at: star + 2, effectiveRange: nil) as? NSFont == Appearance.codeFont())
        #expect(storage.attribute(.inlineMath, at: star, effectiveRange: nil) != nil)
    }

    @Test
    func aQuotedFormulaTakesTheQuoteInk() throws {
        let textView = styledView("> quoted $x$ here\n")
        let storage = try #require(textView.textStorage)
        let math = try #require(storage.attribute(.inlineMath, at: 9, effectiveRange: nil) as? InlineMath)
        #expect(math.color == Appearance.quoteInk)
    }

    // MARK: Layout

    private func layout(_ textView: PaperTextView) throws -> (PaperLayoutManager, NSTextContainer) {
        let layoutManager = try #require(textView.layoutManager as? PaperLayoutManager)
        let container = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        return (layoutManager, container)
    }

    private func fragmentHeight(of marker: String, in textView: PaperTextView) throws -> CGFloat {
        let (layoutManager, _) = try layout(textView)
        let location = (textView.string as NSString).range(of: marker).location
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).height
    }

    @Test
    func aShortFormulaKeepsTheLineHeight() throws {
        let plain = try fragmentHeight(of: "a", in: styledView("a y b\n"))
        #expect(try fragmentHeight(of: "a", in: styledView("a $x$ b\n")) == plain)
        #expect(try fragmentHeight(of: "$", in: styledView("$x$\nb\n")) == plain, "a line with only a formula")
    }

    @Test
    func aTallFormulaMakesRoomForItself() throws {
        let latex = "\\frac{\\sum_{i=1}^{n} x_i}{\\sqrt{n}}"
        let textView = styledView("A mean $\(latex)$ here.\n")
        let (layoutManager, container) = try layout(textView)
        let formulas = layoutManager.inlineFormulas(forGlyphRange: layoutManager.glyphRange(for: container))
        let rect = try #require(formulas.first?.rect)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        #expect(rect.minY >= fragment.minY, "the formula's top stays inside its line")
        #expect(try fragmentHeight(of: "A", in: textView) > fragmentHeight(of: "a", in: styledView("a y b\n")))
    }

    @Test
    func theFormulaSitsOnTheBaseline() throws {
        let textView = styledView("Before $x_1 + y$ after.\n")
        let (layoutManager, container) = try layout(textView)
        let rect = try #require(layoutManager.inlineFormulas(forGlyphRange: layoutManager.glyphRange(for: container)).first)
        guard case .success(let formula) = MathStore.shared.typeset("x_1 + y", style: .inline, size: rect.math.size) else {
            Issue.record("expected a formula")
            return
        }
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let baseline = fragment.minY + layoutManager.location(forGlyphAt: 0).y
        #expect(abs(rect.rect.minY + formula.ascent - baseline) < 0.001)
        let before = layoutManager.boundingRect(forGlyphRange: NSRange(location: 0, length: 6), in: container)
        #expect(rect.rect.minX >= before.maxX, "after the text before it")
    }

    @Test
    func revealingAFormulaKeepsTheDocumentHeight() throws {
        let textView = styledView("Before.\n\nA fraction $\\frac{a+b}{c}$ here.\n\nafter")
        let (layoutManager, container) = try layout(textView)
        let text = textView.string as NSString
        let paragraph = text.paragraphRange(for: text.range(of: "fraction"))
        let after = text.range(of: "after")
        func afterTop() -> CGFloat {
            layoutManager.lineFragmentRect(
                forGlyphAt: layoutManager.glyphIndexForCharacter(at: after.location), effectiveRange: nil
            ).minY
        }

        layoutManager.setActiveRange(NSRange(location: 0, length: 0))
        layoutManager.ensureLayout(for: container)
        let concealedHeight = layoutManager.usedRect(for: container).height
        let concealedAfter = afterTop()
        #expect(layoutManager.inlineFormulas(forGlyphRange: layoutManager.glyphRange(for: container)).count == 1)

        layoutManager.setActiveRange(paragraph)
        layoutManager.ensureLayout(for: container)
        #expect(layoutManager.usedRect(for: container).height == concealedHeight)
        #expect(afterTop() == concealedAfter)
        #expect(layoutManager.inlineFormulas(forGlyphRange: layoutManager.glyphRange(for: container)).isEmpty, "the source shows instead")
    }

    @Test
    func aFormulaNeverRunsPastTheMeasure() throws {
        for words in 0..<40 {
            let prefix = String(repeating: "word ", count: words)
            let textView = styledView(prefix + "then $\\frac{a+b}{c+d} = e$ and more text follows here.\n", width: 500)
            let (layoutManager, container) = try layout(textView)
            let right = container.size.width - container.lineFragmentPadding
            for formula in layoutManager.inlineFormulas(forGlyphRange: layoutManager.glyphRange(for: container)) {
                #expect(formula.rect.maxX <= right + 0.5, "\(words) words before it: \(formula.rect.maxX) past \(right)")
            }
        }
    }

    @Test
    func aFormulaDraws() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let textView = PaperTextView()
        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Appearance.canvas
        textView.frame = scrollView.bounds
        // Only the formula: its source conceals, so every inked pixel is it.
        textView.string = "$\\sum_{k=0}^{n} k^2$\n"
        textView.syntaxStyler.apply(to: textView)
        scrollView.layoutSubtreeIfNeeded()
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let rep = try #require(scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds))
        scrollView.cacheDisplay(in: scrollView.bounds, to: rep)
        let canvas = try #require(rep.colorAt(x: 1, y: 1)?.brightnessComponent)
        let inked = (0..<rep.pixelsWide).reduce(0) { count, x in
            count + (0..<rep.pixelsHigh).filter { y in
                abs((rep.colorAt(x: x, y: y)?.brightnessComponent ?? canvas) - canvas) > 0.3
            }.count
        }
        #expect(inked > 30, "the formula is drawn in ink")
    }
}
