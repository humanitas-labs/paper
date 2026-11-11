import AppKit
import Testing
@testable import Paper

/// A selection that starts at an indented paragraph's start draws its
/// first line from the leading edge, like the wrapped lines under it.
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

    private func lines(_ layoutManager: PaperLayoutManager, for range: NSRange) -> [NSRect] {
        var rects: [NSRect] = []
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in rects.append(rect) }
        return rects
    }

    @Test(arguments: [0, 6])
    func theFirstLineOfAnItemReachesTheLeadingEdge(start: Int) throws {
        let text = "Before.\n\n" + Self.item + "\n\nAfter."
        let (textView, layoutManager) = editor(text)
        let location = (text as NSString).range(of: "- [ ]").location + start
        let range = NSRange(location: location, length: (text as NSString).range(of: "\n\nAfter").location - location)
        let fragments = lines(layoutManager, for: range)
        try #require(fragments.count > 1)
        let padding = textView.textContainer!.lineFragmentPadding
        let first = layoutManager.boundingRect(
            forGlyphRange: layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil),
            in: textView.textContainer!
        )
        // What TextKit hands over: the first line from its first glyph,
        // the rest from the fragment's edge.
        var rects = fragments.map { NSRect(x: $0.minX + padding, y: $0.minY, width: $0.width - 2 * padding, height: $0.height) }
        rects[0].origin.x = first.minX
        rects[0].size.width -= first.minX - (fragments[0].minX + padding)
        try #require(rects[0].minX > rects[1].minX)

        let squared = layoutManager.squaredToLeadingEdge(rects, forCharacterRange: range, origin: .zero)
        #expect(squared[0].minX == squared[1].minX)
        #expect(squared[0].maxX == rects[0].maxX)
        #expect(Array(squared.dropFirst()) == Array(rects.dropFirst()))
    }

    @Test
    func aSelectionFromMidLineIsLeftAlone() {
        let text = Self.item
        let (_, layoutManager) = editor(text)
        let location = (text as NSString).range(of: "item").location
        let range = NSRange(location: location, length: text.utf16.count - location)
        let fragments = lines(layoutManager, for: range)
        var rects = fragments
        rects[0].origin.x += 80
        rects[0].size.width -= 80
        #expect(layoutManager.squaredToLeadingEdge(rects, forCharacterRange: range, origin: .zero) == rects)
    }
}
