import AppKit
import Testing
@testable import Paper

/// Unordered list markers render as Apple Notes' two list kinds off the
/// active paragraph: `-` as an en dash, `*` and `+` as a bullet. The source
/// characters never change.
@MainActor
struct ListMarkerTests {
    private func makeTextView(_ text: String, selectedAt location: Int) -> (PaperTextView, PaperLayoutManager) {
        let textView = PaperTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        textView.string = text
        textView.syntaxStyler.apply(to: textView)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        let layoutManager = textView.layoutManager as! PaperLayoutManager
        layoutManager.ensureLayout(for: textView.textContainer!)
        return (textView, layoutManager)
    }

    private func glyph(_ layoutManager: NSLayoutManager, characterAt index: Int) -> CGGlyph {
        layoutManager.cgGlyph(at: layoutManager.glyphIndexForCharacter(at: index))
    }

    @Test
    func anEmptyItemIsStyledLikeItsListBeforeAnyTextIsTyped() throws {
        // The state right after Return continues a list: `- ` and a caret.
        let text = "- one\n- "
        let (textView, _) = makeTextView(text, selectedAt: text.utf16.count)
        let storage = try #require(textView.textStorage)
        let empty = (text as NSString).range(of: "- ", options: .backwards)
        #expect(storage.attribute(.glyphSubstitute, at: empty.location, effectiveRange: nil) as? String == "–")
        let style = try #require(
            storage.attribute(.paragraphStyle, at: empty.location, effectiveRange: nil) as? NSParagraphStyle
        )
        let first = try #require(
            storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        #expect(style.firstLineHeadIndent == first.firstLineHeadIndent,
                "the empty item's marker sits where the list's markers sit")
    }

    @Test
    func nestedItemsStepByAFullNestingIncrement() throws {
        let text = "- top\n  - nested\n    - deeper\n"
        let (textView, _) = makeTextView(text, selectedAt: text.utf16.count)
        let storage = try #require(textView.textStorage)
        func style(at index: Int) throws -> NSParagraphStyle {
            try #require(storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
        }
        // The marker's visual position is the indent plus the rendered
        // leading spaces; together they land on the nesting step.
        let spaces = ("  " as NSString).size(withAttributes: [.font: Appearance.bodyFont()]).width
        #expect(try style(at: 0).firstLineHeadIndent == Appearance.listIndent)
        #expect(abs(try style(at: 6).firstLineHeadIndent + spaces
                    - (Appearance.listIndent + Appearance.listNestIndent)) < 0.5)
        #expect(abs(try style(at: 17).firstLineHeadIndent + 2 * spaces
                    - (Appearance.listIndent + 2 * Appearance.listNestIndent)) < 0.5)
    }

    @Test
    func dashAndStarRenderAsDashAndBulletOffTheActiveParagraph() throws {
        let text = "- dash\n* star\n+ plus\n1. one\n\nbody\n"
        let (textView, layoutManager) = makeTextView(text, selectedAt: text.utf16.count)
        let storage = try #require(textView.textStorage)
        // Marker characters carry a font that has the rendered glyph, which
        // may be a cascade fallback when the body face lacks it.
        let dashFont = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let bulletFont = try #require(storage.attribute(.font, at: 7, effectiveRange: nil) as? NSFont)
        let dash = try #require(PaperLayoutManager.glyph(for: "–", in: dashFont))
        let bullet = try #require(PaperLayoutManager.glyph(for: "•", in: bulletFont))
        let hyphen = try #require(PaperLayoutManager.glyph(for: "-", in: dashFont))

        #expect(storage.attribute(.glyphSubstitute, at: 0, effectiveRange: nil) as? String == "–")
        #expect(storage.attribute(.glyphSubstitute, at: 7, effectiveRange: nil) as? String == "•")
        #expect(storage.attribute(.glyphSubstitute, at: 14, effectiveRange: nil) as? String == "•")
        #expect(storage.attribute(.glyphSubstitute, at: 21, effectiveRange: nil) == nil, "ordered markers are untouched")
        #expect(glyph(layoutManager, characterAt: 0) == dash)
        #expect(glyph(layoutManager, characterAt: 7) == bullet)
        #expect(glyph(layoutManager, characterAt: 14) == bullet)
        #expect(glyph(layoutManager, characterAt: 2) != dash, "content glyphs are not substituted")

        // The marker holds on the active paragraph too (#50): the item
        // never reflows when the caret enters it.
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        layoutManager.ensureLayout(for: textView.textContainer!)
        #expect(glyph(layoutManager, characterAt: 0) == dash, "the active paragraph keeps its rendered marker")
        #expect(glyph(layoutManager, characterAt: 0) != hyphen)
        #expect(glyph(layoutManager, characterAt: 7) == bullet)
        #expect(storage.attribute(.listMarker, at: 0, effectiveRange: nil) as? Bool == true)
        #expect(storage.attribute(.listMarker, at: 21, effectiveRange: nil) as? Bool == true, "ordered markers are units too")
        #expect(textView.string == text)
    }

    @Test
    func listItemsHangUnderTheirTextAndQuotesKeepTheirOwnIndent() throws {
        let (textView, _) = makeTextView("- item\n\nplain\n\n> - quoted item\n", selectedAt: 0)
        let storage = try #require(textView.textStorage)
        let item = storage.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as? NSParagraphStyle
        let plain = storage.attribute(.paragraphStyle, at: 9, effectiveRange: nil) as? NSParagraphStyle
        let quoted = storage.attribute(.paragraphStyle, at: 18, effectiveRange: nil) as? NSParagraphStyle
        let expected = ("– " as NSString).size(withAttributes: [.font: Appearance.bodyFont()]).width

        #expect(item?.firstLineHeadIndent == Appearance.listIndent)
        #expect(item?.headIndent == Appearance.listIndent + Appearance.listMarkerGap + expected)
        #expect(storage.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat == Appearance.letterSpacing + Appearance.listMarkerGap)
        #expect(storage.attribute(.kern, at: 2, effectiveRange: nil) as? CGFloat == Appearance.letterSpacing)
        #expect(plain?.headIndent == 0)
        #expect(quoted?.firstLineHeadIndent == Appearance.quoteIndent)
        #expect(quoted?.headIndent == Appearance.quoteIndent)
        #expect(storage.attribute(.glyphSubstitute, at: 17, effectiveRange: nil) as? String == "–", "a list inside a quote still gets its marker")
    }

    @Test
    func hardWrappedItemsContinueUnderTheirText() throws {
        let text = "- first line of an item\nsecond line\nthird line\n\nplain\n- next\n"
        let (textView, _) = makeTextView(text, selectedAt: 0)
        let storage = try #require(textView.textStorage)
        func style(_ index: Int) -> NSParagraphStyle? {
            storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        }
        let item = try #require(style(2))
        let second = try #require(style(26))
        let third = try #require(style(38))
        let plain = try #require(style(50))
        let next = try #require(style(58))

        #expect(item.paragraphSpacing == 0, "no gap before its continuation")
        #expect(second.firstLineHeadIndent == item.headIndent)
        #expect(second.headIndent == item.headIndent)
        #expect(second.paragraphSpacing == 0)
        #expect(third.firstLineHeadIndent == item.headIndent)
        #expect(third.paragraphSpacing == Appearance.paragraphSpacing, "last continuation keeps the gap")
        #expect(plain.headIndent == 0)
        #expect(next.paragraphSpacing == Appearance.paragraphSpacing, "an item followed by another item has no continuation")
        #expect(storage.attribute(.glyphSubstitute, at: 24, effectiveRange: nil) == nil)
        #expect(textView.string == text)
    }

    @Test
    func indentedContinuationsConcealTheirLeadingWhitespace() throws {
        let text = "- first line of an item\n  second line\n\tthird line\nfourth\n"
        let (textView, layoutManager) = makeTextView(text, selectedAt: text.utf16.count)
        let storage = try #require(textView.textStorage)
        var range = NSRange()
        #expect(storage.attribute(.concealable, at: 24, effectiveRange: &range) as? Bool == true)
        #expect(range == NSRange(location: 24, length: 2), "both leading spaces")
        #expect(storage.attribute(.concealable, at: 38, effectiveRange: &range) as? Bool == true)
        #expect(range == NSRange(location: 38, length: 1), "a leading tab")
        #expect(storage.attribute(.concealable, at: 50, effectiveRange: nil) == nil, "an unindented continuation has nothing to hide")

        // The continuation's text starts where the item's text does, off
        // the active paragraph and on it alike: the indent is pinned, so
        // the caret entering the line moves nothing sideways.
        let itemX = layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: 2)).x
        let concealedX = layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: 26)).x
        #expect(abs(itemX - concealedX) < 0.5, "item text at \(itemX), continuation at \(concealedX)")
        textView.setSelectedRange(NSRange(location: 30, length: 0))
        layoutManager.ensureLayout(for: textView.textContainer!)
        let activeX = layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: 26)).x
        #expect(abs(itemX - activeX) < 0.5, "on the active paragraph the continuation stays at \(itemX), not \(activeX)")
        #expect(layoutManager.isConcealed(characterAt: 24), "the indent stays concealed under the caret")
        #expect(textView.string == text)
    }

    @Test
    func wrappedLinesStartExactlyUnderTheFirstLinesText() throws {
        let text = "- " + Array(repeating: "wrapping words", count: 40).joined(separator: " ") + "\n"
        let (textView, layoutManager) = makeTextView(text, selectedAt: text.utf16.count)
        let container = try #require(textView.textContainer)
        textView.setFrameSize(NSSize(width: 320, height: 600))
        layoutManager.ensureLayout(for: container)

        // x of the first content glyph on line 1 versus the first glyph on line 2.
        let firstContent = layoutManager.glyphIndexForCharacter(at: 2)
        let firstLine = layoutManager.lineFragmentRect(forGlyphAt: firstContent, effectiveRange: nil)
        var secondLineRange = NSRange()
        _ = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.numberOfGlyphs - 2, effectiveRange: nil)
        var glyphIndex = firstContent
        while glyphIndex < layoutManager.numberOfGlyphs {
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &secondLineRange)
            if rect.minY > firstLine.minY { break }
            glyphIndex = NSMaxRange(secondLineRange)
        }
        #expect(glyphIndex < layoutManager.numberOfGlyphs, "the item wraps")
        let firstX = layoutManager.location(forGlyphAt: firstContent).x
        let secondX = layoutManager.location(forGlyphAt: glyphIndex).x
        #expect(abs(firstX - secondX) < 0.5, "first line text at \(firstX), wrapped line at \(secondX)")
    }

    @Test
    func orderedMarkersKernOnlyAfterTheirLastCharacter() throws {
        let text = "12. " + Array(repeating: "wrapping words", count: 40).joined(separator: " ") + "\n"
        let (textView, layoutManager) = makeTextView(text, selectedAt: text.utf16.count)
        let storage = try #require(textView.textStorage)
        #expect(storage.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat == Appearance.letterSpacing)
        #expect(storage.attribute(.kern, at: 1, effectiveRange: nil) as? CGFloat == Appearance.letterSpacing)
        #expect(storage.attribute(.kern, at: 2, effectiveRange: nil) as? CGFloat == Appearance.letterSpacing + Appearance.listMarkerGap)

        textView.setFrameSize(NSSize(width: 320, height: 600))
        layoutManager.ensureLayout(for: textView.textContainer!)
        let firstContent = layoutManager.glyphIndexForCharacter(at: 4)
        let firstLine = layoutManager.lineFragmentRect(forGlyphAt: firstContent, effectiveRange: nil)
        var lineRange = NSRange()
        var glyphIndex = firstContent
        while glyphIndex < layoutManager.numberOfGlyphs {
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
            if rect.minY > firstLine.minY { break }
            glyphIndex = NSMaxRange(lineRange)
        }
        let firstX = layoutManager.location(forGlyphAt: firstContent).x
        let secondX = layoutManager.location(forGlyphAt: glyphIndex).x
        #expect(abs(firstX - secondX) < 0.5, "first line text at \(firstX), wrapped line at \(secondX)")
    }

    @Test
    func orderedMarkersMayCarryALetterSuffix() throws {
        let text = "1a) Commercial society.\n1b. Revolutions.\n2A) Upper.\n\na) bare letter\n"
        let (textView, _) = makeTextView(text, selectedAt: text.utf16.count)
        let storage = try #require(textView.textStorage)
        func style(_ index: Int) -> NSParagraphStyle? {
            storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        }
        #expect(style(4)?.firstLineHeadIndent == Appearance.listIndent, "1a)")
        #expect(storage.attribute(.kern, at: 2, effectiveRange: nil) as? CGFloat == Appearance.letterSpacing + Appearance.listMarkerGap, "gap after `)`")
        #expect(style(28)?.firstLineHeadIndent == Appearance.listIndent, "1b.")
        #expect(style(45)?.firstLineHeadIndent == Appearance.listIndent, "2A)")
        #expect(style(56)?.firstLineHeadIndent == Appearance.listIndent, "a bare letter is a marker too (#70)")
        #expect(storage.attribute(.glyphSubstitute, at: 0, effectiveRange: nil) == nil, "ordered markers keep their glyphs")
    }

    @Test
    func letteredMarkersAreOrderedItems() throws {
        // #70: `a. ` and `a) ` are list prefixes like `1. `, muted and
        // hanging, their punctuation kept as written. Only a single letter
        // qualifies; abbreviations and words stay prose.
        let text = "a. no catalyzing event\nB) second\n  - nested under it\n1. top\n   c. nested letter\n\na.m. call\n\nab. word\n"
        let (textView, _) = makeTextView(text, selectedAt: text.utf16.count)
        let storage = try #require(textView.textStorage)
        let source = text as NSString
        func style(_ needle: String) -> NSParagraphStyle? {
            storage.attribute(.paragraphStyle, at: source.range(of: needle).location, effectiveRange: nil) as? NSParagraphStyle
        }
        func ink(_ needle: String) -> NSColor? {
            storage.attribute(.foregroundColor, at: source.range(of: needle).location, effectiveRange: nil) as? NSColor
        }
        #expect(style("a. no")?.firstLineHeadIndent == Appearance.listIndent, "a.")
        #expect(ink("a. no") == Appearance.mutedInk, "the marker is muted like a number")
        #expect(storage.attribute(.kern, at: 1, effectiveRange: nil) as? CGFloat == Appearance.letterSpacing + Appearance.listMarkerGap, "gap after the period")
        #expect(storage.attribute(.glyphSubstitute, at: 0, effectiveRange: nil) == nil, "`a.` keeps its glyphs")
        #expect(storage.attribute(.listMarker, at: 0, effectiveRange: nil) as? Bool == true)
        #expect(style("B) second")?.firstLineHeadIndent == Appearance.listIndent, "B)")
        let one = try #require(style("1. top"))
        let nestedBullet = try #require(style("- nested"))
        let nestedLetter = try #require(style("c. nested"))
        #expect(nestedBullet.firstLineHeadIndent > one.firstLineHeadIndent, "a bullet nests under a lettered item")
        #expect(nestedLetter.firstLineHeadIndent > one.firstLineHeadIndent, "a lettered item nests under a number")
        #expect(style("a.m.")?.firstLineHeadIndent == 0, "an abbreviation is prose")
        #expect(ink("a.m.") == Appearance.ink)
        #expect(style("ab.")?.firstLineHeadIndent == 0, "two letters are prose")
        #expect(textView.string == text)
    }

    @Test
    func arrowsDrawAsOneGlyphOffTheActiveParagraph() throws {
        let text = "a -> b, `x -> y`, c --> d\n"
        let (textView, layoutManager) = makeTextView(text, selectedAt: text.utf16.count)
        let storage = try #require(textView.textStorage)
        let font = try #require(storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)
        let arrow = try #require(PaperLayoutManager.glyph(for: "→", in: font))
        #expect(storage.attribute(.concealable, at: 2, effectiveRange: nil) as? Bool == true, "`-` hides")
        #expect(storage.attribute(.glyphSubstitute, at: 3, effectiveRange: nil) as? String == "→")
        #expect(glyph(layoutManager, characterAt: 3) == arrow)
        #expect(storage.attribute(.glyphSubstitute, at: 12, effectiveRange: nil) == nil, "code spans keep `->`")
        #expect(storage.attribute(.glyphSubstitute, at: 22, effectiveRange: nil) == nil, "`-->` is not an arrow")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        layoutManager.ensureLayout(for: textView.textContainer!)
        #expect(glyph(layoutManager, characterAt: 3) != arrow, "the active paragraph shows the source")
        #expect(textView.string == text)
    }

    @Test
    func markersNeedTheirSpaceAndAreNotMatchedMidLine() throws {
        let (textView, _) = makeTextView("-\n- \na - b\n  - nested\n", selectedAt: 30)
        let storage = try #require(textView.textStorage)
        #expect(storage.attribute(.glyphSubstitute, at: 0, effectiveRange: nil) == nil, "bare dash")
        #expect(storage.attribute(.glyphSubstitute, at: 2, effectiveRange: nil) as? String == "–",
                "an empty item is already a list item")
        #expect(storage.attribute(.glyphSubstitute, at: 7, effectiveRange: nil) == nil, "mid-line dash")
        #expect(storage.attribute(.glyphSubstitute, at: 13, effectiveRange: nil) as? String == "–", "nested item")
    }
}
