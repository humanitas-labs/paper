import AppKit
import Testing
@testable import Paper

/// A selection's highlight covers text, not the gutter beside it: on a
/// list item every line starts at the item's text, so the marker's column
/// and the task circle in it stay clear (PAP-0017, PAP-0018).
@MainActor
struct SelectionRectTests {
    private static let item = "- [ ] An item that runs long enough to wrap onto a second line of the measure, and then some more words to be sure of it"

    private func editor(_ text: String) -> (PaperTextView, PaperLayoutManager) {
        let textView = PaperTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        textView.string = text
        textView.syntaxStyler.apply(to: textView)
        let layoutManager = textView.layoutManager as! PaperLayoutManager
        layoutManager.ensureLayout(for: textView.textContainer!)
        return (textView, layoutManager)
    }

    private func fragments(_ layoutManager: PaperLayoutManager, for range: NSRange) -> [NSRect] {
        var rects: [NSRect] = []
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        // As TextKit hands a full line over: the fragment less its padding.
        let padding = layoutManager.textContainers[0].lineFragmentPadding
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
            rects.append(rect.insetBy(dx: padding, dy: 0))
        }
        return rects
    }

    /// Where the item's text starts on its first line, in container
    /// coordinates.
    private func textStart(_ text: String, _ textView: PaperTextView, _ layoutManager: PaperLayoutManager) -> CGFloat {
        let first = (text as NSString).range(of: "An item")
        return layoutManager.boundingRect(
            forGlyphRange: layoutManager.glyphRange(forCharacterRange: NSRange(location: first.location, length: 1), actualCharacterRange: nil),
            in: textView.textContainer!
        ).minX
    }

    @Test
    func everyLineOfASelectedItemStartsAtItsText() throws {
        let text = "Before.\n\n" + Self.item + "\n\nAfter."
        let (textView, layoutManager) = editor(text)
        let range = (text as NSString).range(of: Self.item)
        let lines = fragments(layoutManager, for: range)
        try #require(lines.count > 1)
        let start = textStart(text, textView, layoutManager)
        try #require(start > lines[0].minX + 10)
        _ = textView

        // As TextKit hands them over: full-width bands from the edge.
        let onText = layoutManager.rectsOnText(lines, forCharacterRange: range, origin: .zero)
        #expect(onText.count == lines.count)
        for (rect, line) in zip(onText, lines) {
            #expect(abs(rect.minX - start) < 0.5)
            #expect(rect.maxX == line.maxX)
            #expect(abs(rect.minY - line.minY) < 0.01 && abs(rect.height - line.height) < 0.01)
        }
        // One tall rect over all the lines is cut to the same pieces.
        let tall = lines.dropFirst().reduce(lines[0]) { $0.union($1) }
        let cut = layoutManager.rectsOnText([tall], forCharacterRange: range, origin: .zero)
        #expect(cut.count == onText.count)
        #expect(zip(cut, onText).allSatisfy { abs($0.minX - $1.minX) < 0.01 && abs($0.minY - $1.minY) < 0.01 && abs($0.height - $1.height) < 0.01 })
    }

    @Test
    func theTaskCircleLiesOutsideTheHighlight() throws {
        let text = Self.item
        let (textView, layoutManager) = editor(text)
        let range = NSRange(location: 0, length: text.utf16.count)
        let lines = fragments(layoutManager, for: range)
        let onText = layoutManager.rectsOnText(lines, forCharacterRange: range, origin: .zero)
        let start = textStart(text, textView, layoutManager)
        #expect(onText.allSatisfy { $0.minX >= start - 0.5 })
        #expect(start - lines[0].minX >= Appearance.taskBoxSize - 0.5)
    }

    @Test
    func aPlainParagraphAndAMidLineSelectionAreLeftAlone() {
        let text = "A plain paragraph that runs long enough to wrap onto a second line of the measure, and then some more words to be sure of it.\n\n" + Self.item
        let (_, layoutManager) = editor(text)
        let plain = fragments(layoutManager, for: NSRange(location: 0, length: 20))
        #expect(layoutManager.rectsOnText(plain, forCharacterRange: NSRange(location: 0, length: 20), origin: .zero) == plain)

        let item = fragments(layoutManager, for: (text as NSString).range(of: Self.item))
        var mid = item
        mid[0].origin.x += 200
        mid[0].size.width -= 200
        let onText = layoutManager.rectsOnText(mid, forCharacterRange: (text as NSString).range(of: Self.item), origin: .zero)
        #expect(onText[0] == mid[0])
    }

    /// The first item under a heading: TextKit's rect for its first line
    /// can reach a hair above the line, into the blank line over it, which
    /// has no indent. No piece of the highlight may lie left of the text
    /// (PAP-0019).
    @Test
    func theFirstItemUnderAHeadingHasNoSliverInTheGutter() throws {
        let text = "# Attention\n\n### Needs your go\n\n" + Self.item + "\n" + Self.item.replacingOccurrences(of: "An item", with: "Another") + "\n\nAfter."
        let (textView, layoutManager) = editor(text)
        let range = (text as NSString).range(of: Self.item)
        let start = textStart(text, textView, layoutManager)
        var count = 0
        let pointer = try #require(layoutManager.rectArray(forCharacterRange: range, withinSelectedCharacterRange: range, in: textView.textContainer!, rectCount: &count))
        var rects = Array(UnsafeBufferPointer(start: pointer, count: count))
        try #require(rects.count > 1)
        // As drawn: the first line's rect reaches a point over the line.
        rects[0].origin.y -= 0.8
        rects[0].size.height += 0.8
        let cut = layoutManager.rectsOnText(rects, forCharacterRange: range, origin: .zero)
        #expect(cut.count == rects.count)
        #expect(cut.allSatisfy { $0.minX >= start - 0.5 })
        #expect(abs(cut[0].minY - rects[0].minY) < 0.01, "the hair stays with the first line")
        #expect(abs(cut[cut.count - 1].maxY - rects[rects.count - 1].maxY) < 0.01)
    }
}
