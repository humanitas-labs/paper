import AppKit
import Testing
@testable import Paper

/// Display math: `$$ … $$` blocks and `math` fences draw as the typeset
/// formula in a band the closing line's spacing reserves. The source is
/// never edited, the band is the same whether the block is concealed or
/// revealed, and source that does not parse stays visible with its error.
@MainActor
struct MathTests {
    private func styledView(_ text: String) -> PaperTextView {
        let textView = PaperTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        textView.string = text
        textView.syntaxStyler.apply(to: textView)
        return textView
    }

    private func blocks(_ source: String) -> [String] {
        let range = NSRange(location: 0, length: source.utf16.count)
        let fenced = MarkdownSyntaxStyler.fencedBlocks(in: source, range: range)
        return MarkdownSyntaxStyler.mathBlocks(in: source, range: range, fenced: fenced, comments: [])
            .map { ($0.latex).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func spacing(at location: Int, in textView: PaperTextView) -> CGFloat {
        (textView.textStorage!.attribute(.paragraphStyle, at: location, effectiveRange: nil) as! NSParagraphStyle).paragraphSpacing
    }

    // MARK: Recognition

    @Test
    func blocksAreRecognisedByTheirDelimiters() {
        #expect(blocks("$$x^2$$\n") == ["x^2"])
        #expect(blocks("$$\na + b\n= c\n$$\n") == ["a + b\n= c"])
        #expect(blocks("$$ a\nb $$\n") == ["a\nb"])
        #expect(blocks("   $$x$$\n") == ["x"], "three spaces of indent is still a block")
        #expect(blocks("```math\n\\sum_i x_i\n```\n") == ["\\sum_i x_i"])
    }

    @Test
    func thingsThatAreNotBlocksStayProse() {
        #expect(blocks("$$\nnever closed\n").isEmpty, "unterminated")
        #expect(blocks("$$\na\n\nb\n$$\n").isEmpty, "a blank line ends the attempt")
        #expect(blocks("$$$$\n").isEmpty, "empty")
        #expect(blocks("    $$x$$\n").isEmpty, "four spaces is code, not math")
        #expect(blocks("It costs $$5 or so$$ in total.\n").isEmpty, "not at the line's start")
        #expect(blocks("```\n$$x$$\n```\n").isEmpty, "inside a fence")
        #expect(blocks("```swift\nlet m = 1\n```\n").isEmpty, "a fence of another language")
    }

    @Test
    func stylingLeavesTheSourceUnchanged() {
        let source = "Before\n\n$$\n\\frac{a}{b}\n$$\n\n```math\nx\n```\n\nAfter\n"
        let textView = styledView(source)
        #expect(textView.string == source)
    }

    // MARK: The band

    @Test
    func aBlockReservesItsFormulaUnderTheClosingLine() throws {
        let textView = styledView("$$\n\\int_0^1 x\\,dx\n$$\n\nafter")
        let text = textView.string as NSString
        let closing = text.range(of: "$$", options: .backwards).location
        let height = MathStore.shared.bandHeight(for: "\n\\int_0^1 x\\,dx", width: MarkdownSyntaxStyler.measure(of: textView))
        #expect(height > Appearance.bodySize, "an integral is taller than a line")
        #expect(spacing(at: closing, in: textView) == height + Appearance.paragraphSpacing)
        #expect(spacing(at: 0, in: textView) == 0, "rows inside the block are flush")

        let storage = try #require(textView.textStorage)
        #expect(storage.attribute(.concealable, at: 1, effectiveRange: nil) != nil, "the source conceals")
        #expect(storage.attribute(.glyphSubstitute, at: 0, effectiveRange: nil) as? String == " ")
        #expect(storage.attribute(.mathSource, at: text.range(of: "after").location, effectiveRange: nil) == nil)
    }

    @Test
    func aMathFenceIsMathNotCode() throws {
        let textView = styledView("```math\ne^{i\\pi} + 1 = 0\n```\n")
        let storage = try #require(textView.textStorage)
        #expect(storage.attribute(.mathSource, at: 10, effectiveRange: nil) != nil)
        #expect(storage.attribute(.codeBlock, at: 10, effectiveRange: nil) == nil, "no code band behind the formula")
    }

    @Test
    func sourceThatDoesNotParseStaysVisible() throws {
        let textView = styledView("$$\\frac{a}{$$\n\nafter")
        let storage = try #require(textView.textStorage)
        guard case .failure = MathStore.shared.display("\\frac{a}{") else {
            Issue.record("expected a parse error")
            return
        }
        #expect(storage.attribute(.concealable, at: 3, effectiveRange: nil) == nil)
        #expect(storage.attribute(.mathSource, at: 3, effectiveRange: nil) != nil, "still math, so not spell-checked")
        #expect(spacing(at: 0, in: textView) > Appearance.paragraphSpacing, "a band for the message")
    }

    @Test
    func mathIsNotCheckedAsProse() throws {
        let textView = styledView("$$\n\\alpha + \\beta\n$$\n")
        #expect(textView.touchesCode(NSRange(location: 4, length: 5)))
    }

    @Test
    func emphasisDoesNotReachIntoMath() throws {
        let textView = styledView("$$\na_1 + b_2 * c * d\n$$\n")
        let storage = try #require(textView.textStorage)
        let font = try #require(storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)
        #expect(font == Appearance.codeFont())
    }

    // MARK: Reveal

    @Test
    func revealingABlockKeepsTheDocumentHeight() throws {
        let textView = styledView("# Title\n\n$$\n\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}\n$$\n\nafter")
        let layoutManager = try #require(textView.layoutManager as? PaperLayoutManager)
        let container = try #require(textView.textContainer)
        let text = textView.string as NSString
        let block = NSUnionRange(
            text.paragraphRange(for: text.range(of: "$$")),
            text.paragraphRange(for: text.range(of: "$$", options: .backwards))
        )
        let after = text.range(of: "after")
        func afterTop() -> CGFloat {
            layoutManager.lineFragmentRect(
                forGlyphAt: layoutManager.glyphRange(forCharacterRange: after, actualCharacterRange: nil).location,
                effectiveRange: nil
            ).minY
        }

        layoutManager.setActiveRange(NSRange(location: 0, length: 0))
        layoutManager.ensureLayout(for: container)
        let concealedHeight = layoutManager.usedRect(for: container).height
        let concealedAfter = afterTop()
        let concealed = layoutManager.mathBands(forGlyphRange: layoutManager.glyphRange(for: container), width: 640)

        layoutManager.setActiveRange(block)
        layoutManager.ensureLayout(for: container)
        #expect(layoutManager.usedRect(for: container).height == concealedHeight)
        #expect(afterTop() == concealedAfter)
        let revealed = layoutManager.mathBands(forGlyphRange: layoutManager.glyphRange(for: container), width: 640)
        #expect(concealed.count == 1 && revealed.count == 1)
        #expect(concealed.first?.active == false && revealed.first?.active == true)
        #expect(concealed.first?.band == revealed.first?.band)
    }

    @Test
    func theCaretOnAnyRowRevealsTheWholeBlock() throws {
        let textView = styledView("$$\na\n+ b\n$$\n\nafter")
        let layoutManager = try #require(textView.layoutManager as? PaperLayoutManager)
        let text = textView.string as NSString
        textView.setSelectedRange(NSRange(location: text.range(of: "+ b").location, length: 0))
        let active = layoutManager.activeRange
        #expect(NSLocationInRange(0, active), "the opening row")
        #expect(NSLocationInRange(text.range(of: "$$", options: .backwards).location, active), "the closing row")
        #expect(!NSLocationInRange(text.range(of: "after").location, active))
    }

    // MARK: Typesetting

    @Test
    func aWideFormulaFitsTheMeasure() throws {
        let latex = String(repeating: "a + ", count: 80) + "z"
        guard case .success(let formula) = MathStore.shared.display(latex) else {
            Issue.record("expected a formula")
            return
        }
        #expect(formula.width > 400)
        let fitted = formula.fitted(to: 400)
        #expect(abs(fitted.width - 400) < 0.001)
        #expect(abs(fitted.height - formula.height * 400 / formula.width) < 0.001)
        #expect(formula.fitted(to: 10_000).width == formula.width, "never scaled up")
    }

    @Test
    func theExpandedViewIsAVectorPDF() throws {
        MathStore.removePreviewFiles()
        let url = try #require(MathStore.shared.previewFile(for: "\\frac{Q(P - V)}{Q(P - V) - F}"))
        let data = try Data(contentsOf: url)
        #expect(String(decoding: data.prefix(5), as: UTF8.self) == "%PDF-")
        #expect(MathStore.shared.previewFile(for: "\\frac{Q(P - V)}{Q(P - V) - F}") == url, "reused, not rewritten")
        #expect(MathStore.shared.previewFile(for: "\\frac{a}{") == nil, "nothing to show for an error")
        MathStore.removePreviewFiles()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func aBlockDrawsItsFormula() throws {
        func render(_ text: String) throws -> NSBitmapImageRep {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            let textView = PaperTextView()
            scrollView.documentView = textView
            scrollView.drawsBackground = true
            scrollView.backgroundColor = Appearance.canvas
            textView.frame = scrollView.bounds
            textView.string = text
            textView.syntaxStyler.apply(to: textView)
            scrollView.layoutSubtreeIfNeeded()
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let rep = try #require(scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds))
            scrollView.cacheDisplay(in: scrollView.bounds, to: rep)
            if let dir = RenderProbeTests.probeDirectory {
                try rep.representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("math-\(abs(text.hashValue)).png"))
            }
            return rep
        }
        // The source conceals, so every pixel off the canvas is the formula.
        let drawn = try render("$$\\sum_{k=0}^{n} k^2$$\n")
        let canvas = try #require(drawn.colorAt(x: 1, y: 1)?.brightnessComponent)
        let inked = (0..<drawn.pixelsWide).reduce(0) { count, x in
            count + (0..<drawn.pixelsHigh).filter { y in
                abs((drawn.colorAt(x: x, y: y)?.brightnessComponent ?? canvas) - canvas) > 0.3
            }.count
        }
        #expect(inked > 50, "the formula is drawn in ink")
    }
}
