import Testing
import UIKit
@testable import Paper

/// Paper's invariants (docs/architecture.md §3) on the UIKit surface.
@MainActor
struct InvariantTests {
    private func makeTextView(_ source: String) -> MobileTextView {
        let textView = MobileTextView()
        textView.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        textView.documentURL = RenderProbeTests.fixtureURL
        textView.load(source)
        textView.layoutIfNeeded()
        return textView
    }

    private var fixture: String {
        get throws { try String(contentsOf: RenderProbeTests.fixtureURL, encoding: .utf8) }
    }

    @Test
    func stylingNeverChangesTheSource() throws {
        let source = try fixture
        let textView = makeTextView(source)
        #expect(textView.textStorage.string == source)
        textView.restyle()
        #expect(textView.textStorage.string == source)
    }

    @Test
    func concealedSyntaxTakesNoWidth() throws {
        let textView = makeTextView("Some **bold** text")
        let layoutManager = textView.paperLayoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        // The opening `**` is concealed off the active paragraph.
        #expect(layoutManager.isConcealed(characterAt: 5))
        let first = layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: 5)).x
        let after = layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: 7)).x
        #expect(abs(after - first) < 0.01)
    }

    @Test
    func revealingAParagraphKeepsTheDocumentHeight() throws {
        let source = try fixture
        let textView = makeTextView(source)
        let layoutManager = textView.paperLayoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        let concealed = layoutManager.usedRect(for: textView.textContainer).height
        let text = source as NSString
        // Every paragraph that holds syntax but no table row: table rows
        // are the one construct whose revealed source may grow (see
        // docs/architecture.md, tables).
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            if text.substring(with: paragraph).hasPrefix("|") { continue }
            let linesBefore = lineCount(of: paragraph, in: layoutManager)
            layoutManager.setActiveRange(paragraph)
            layoutManager.ensureLayout(for: textView.textContainer)
            // Revealed syntax is wider, and at phone width a long paragraph
            // can wrap onto another line; that is the text's own length, as
            // in a narrow Mac window. The invariant is that no line grows.
            guard lineCount(of: paragraph, in: layoutManager) == linesBefore else {
                layoutManager.setActiveRange(NSRange(location: 0, length: 0))
                continue
            }
            let revealed = layoutManager.usedRect(for: textView.textContainer).height
            #expect(abs(revealed - concealed) < 0.5, "paragraph at \(paragraph.location): \(text.substring(with: paragraph))")
            layoutManager.setActiveRange(NSRange(location: 0, length: 0))
        }
    }

    private func lineCount(of paragraph: NSRange, in layoutManager: NSLayoutManager) -> Int {
        let glyphs = layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
        var count = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in count += 1 }
        return count
    }
}
