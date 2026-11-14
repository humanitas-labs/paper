import AppKit
import Testing
@testable import Paper

/// Clicking an outline entry lands that heading at the reading line, in a
/// real window, on a long document with tables, fenced code, task lists,
/// and headings long enough to wrap once their syntax is revealed. In a
/// window the text view lays out lazily and grows its frame behind the
/// layout, which a windowless view never shows.
@MainActor
@Suite(.serialized)
struct OutlineJumpTests {
    private static let document: String = {
        var text = "# Plan: a long document with every kind of block\n\nOpening paragraph.\n\n"
        for section in 1...12 {
            text += "## \(section). Section number \(section)\n\n"
            text += "A paragraph of prose long enough to wrap across the measure once or twice, so the section has height of its own and the page has to scroll.\n\n"
            for sub in 1...3 {
                text += "### \(section).\(sub) `Paper/Editor/SomeLongFileName\(section)\(sub).swift` (changed: a long parenthetical that wraps when the syntax shows)\n\n"
                text += "| Column | Another column | Third |\n|---|---|---|\n| a cell with some words | another cell with more words in it | 3 |\n| short | a cell that wraps inside its column because it is long | 4 |\n\n"
                text += "```swift\n# not a heading\nlet value = \(section * sub)\n```\n\n"
                text += "- [x] T\(sub). A finished task with `code` in it.\n- [ ] T\(sub + 1). An open task that runs long enough to wrap onto a second line in the list.\n\n"
            }
        }
        return text
    }()

    private func makeWindow() -> (NSWindow, NSScrollView, PaperTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1300, height: 800),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let scrollView = PaperScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        let textView = PaperTextView()
        textView.string = Self.document
        textView.syntaxStyler.apply(to: textView)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .legacy
        scrollView.automaticallyAdjustsContentInsets = false
        window.contentView!.addSubview(scrollView)
        return (window, scrollView, textView)
    }

    private func lineTop(of heading: OutlineHeading, in textView: PaperTextView) -> CGFloat {
        let layoutManager = textView.layoutManager!
        let glyph = layoutManager.glyphIndexForCharacter(at: heading.range.location)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textView.textContainerOrigin.y
    }

    /// Where the heading should be: at the reading line, or, when the
    /// document ends too soon for that, with the clip at the very end.
    private func check(_ heading: OutlineHeading, index: Int, model: OutlineModel, scrollView: NSScrollView, textView: PaperTextView, stage: String) {
        // The viewport in the text view's coordinates: its frame does not
        // start at the clip view's origin.
        let visible = textView.visibleRect
        let target = lineTop(of: heading, in: textView) - textView.textContainerInset.height
        // At the end AppKit may settle the clip a few points after the
        // jump (it re-constrains on the next tile), so the end is a band.
        let atEnd = visible.maxY >= textView.bounds.height - 8
        #expect(abs(visible.minY - target) < 1 || (atEnd && visible.minY < target), "\(stage): heading \(index) '\(heading.title)' top \(visible.minY) target \(target)")
        #expect(model.current == index, "\(stage): heading \(index) marked \(String(describing: model.current))")
    }

    @Test
    func jumpLandsEveryHeadingAtTheReadingLine() async throws {
        let (window, scrollView, textView) = makeWindow()
        defer { window.close() }
        let model = OutlineModel()
        model.attach(textView: textView, scrollView: scrollView)
        model.setActive(true)
        #expect(model.headings.count > 40)
        // Start where a reader would be: far down, the caret there.
        textView.setSelectedRange(NSRange(location: (Self.document as NSString).length - 10, length: 0))

        for (index, heading) in model.headings.enumerated() {
            model.jump(to: heading)
            check(heading, index: index, model: model, scrollView: scrollView, textView: textView, stage: "after jump")
            textView.layoutManager!.ensureLayout(for: textView.textContainer!)
            try await Task.sleep(for: .milliseconds(20))
            check(heading, index: index, model: model, scrollView: scrollView, textView: textView, stage: "after layout")
            model.updateCurrent()
            #expect(model.current == index, "the scroll position agrees with the mark for heading \(index)")
        }
    }

    /// The same, jumping backward from the end, where a lazily laid-out
    /// window has the least layout ahead of the target.
    @Test
    func jumpBackwardFromTheEnd() async throws {
        let (window, scrollView, textView) = makeWindow()
        defer { window.close() }
        let model = OutlineModel()
        model.attach(textView: textView, scrollView: scrollView)
        model.setActive(true)
        for (index, heading) in model.headings.enumerated().reversed() {
            model.jump(to: heading)
            check(heading, index: index, model: model, scrollView: scrollView, textView: textView, stage: "after jump")
            try await Task.sleep(for: .milliseconds(20))
            check(heading, index: index, model: model, scrollView: scrollView, textView: textView, stage: "after a run-loop turn")
        }
    }
}
