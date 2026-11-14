import AppKit
import Testing
@testable import Paper

/// The outline's bridge to the editor, on a windowless scroll view and
/// text view (see `TestWindows.swift` for why no window). Nothing here
/// writes through `ConfigurationStore.shared`.
@MainActor
@Suite(.serialized)
struct OutlineModelTests {
    /// A long document: an intro, then `count` sections of body text.
    private func document(sections count: Int = 12) -> String {
        var text = "Intro paragraph before any heading.\n\n"
        for index in 1...count {
            text += index % 3 == 0 ? "### Section \(index)\n\n" : "## Section \(index)\n\n"
            for _ in 0..<6 {
                text += "A paragraph of body text long enough to wrap across the measure at least once, so the sections have height.\n\n"
            }
        }
        return text
    }

    private func makeEditor(_ text: String, width: CGFloat = 1400, height: CGFloat = 800) -> (NSScrollView, PaperTextView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let textView = PaperTextView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        textView.string = text
        textView.syntaxStyler.apply(to: textView)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.sizeToFit()
        return (scrollView, textView)
    }

    private func lineTop(of heading: OutlineHeading, in textView: PaperTextView) -> CGFloat {
        let layoutManager = textView.layoutManager!
        let glyph = layoutManager.glyphIndexForCharacter(at: heading.range.location)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textView.textContainerOrigin.y
    }

    @Test
    func inactiveModelDoesNotScan() async throws {
        let (scrollView, textView) = makeEditor(document())
        let model = OutlineModel()
        model.attach(textView: textView, scrollView: scrollView)
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: textView)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.headings.isEmpty)
        model.scanNow()
        #expect(model.headings.isEmpty, "inactive: even an explicit scan does nothing")
    }

    @Test
    func scansOnActivationAndAfterReplacement() async throws {
        let (scrollView, textView) = makeEditor(document(sections: 3))
        let model = OutlineModel()
        model.attach(textView: textView, scrollView: scrollView)
        model.setActive(true)
        #expect(model.headings.map(\.title) == ["Section 1", "Section 2", "Section 3"])

        textView.string = "# Fresh\n\nbody\n\n## Second\n"
        model.textWasReplaced()
        let deadline = ContinuousClock.now + .seconds(2)
        while model.headings.first?.title != "Fresh", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.headings.map(\.title) == ["Fresh", "Second"])

        model.setActive(false)
        #expect(model.headings.isEmpty)
        #expect(model.current == nil)
    }

    @Test
    func jumpPutsTheHeadingAtThePageTopAndTheCaretOnIt() throws {
        let (scrollView, textView) = makeEditor(document())
        let model = OutlineModel()
        model.attach(textView: textView, scrollView: scrollView)
        model.setActive(true)
        let heading = model.headings[5]
        model.jump(to: heading)

        let clip = scrollView.contentView.bounds
        #expect(abs(clip.minY + textView.textContainerInset.height - lineTop(of: heading, in: textView)) < 1)
        #expect(textView.selectedRange() == NSRange(location: heading.contentRange.location, length: 0))
        #expect(model.current == 5)
        model.updateCurrent()
        #expect(model.current == 5, "the scroll position agrees with the mark")
    }

    @Test
    func jumpNearTheEndClampsAndStillMarks() throws {
        let (scrollView, textView) = makeEditor(document() + "## Last\n\nshort tail\n")
        let model = OutlineModel()
        model.attach(textView: textView, scrollView: scrollView)
        model.setActive(true)
        let last = try #require(model.headings.last)
        model.jump(to: last)
        let clip = scrollView.contentView.bounds
        #expect(abs(clip.maxY - textView.frame.height) < 1, "clamped to the end of the document")
        #expect(model.current == model.headings.count - 1)
    }

    @Test
    func scrollingMovesTheCurrentSection() throws {
        let (scrollView, textView) = makeEditor(document())
        let model = OutlineModel()
        model.attach(textView: textView, scrollView: scrollView)
        model.setActive(true)
        #expect(model.current == nil, "the intro sits above the first heading")

        let third = model.headings[2]
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: lineTop(of: third, in: textView) - textView.textContainerInset.height))
        scrollView.reflectScrolledClipView(clip)
        #expect(model.current == 2)

        clip.scroll(to: .zero)
        scrollView.reflectScrolledClipView(clip)
        #expect(model.current == nil)
    }

    @Test
    func roomIsTheSpaceRightOfTheText() {
        let (scrollView, textView) = makeEditor(document(sections: 2))
        let model = OutlineModel()
        model.attach(textView: textView, scrollView: scrollView)
        model.setActive(true)
        let container = textView.textContainer!
        let textRight = textView.textContainerOrigin.x + container.size.width
        #expect(abs(model.room - (scrollView.bounds.width - textRight)) < 1)
        #expect(model.top == textView.textContainerInset.height)
    }

    @Test
    func columnWidthFollowsTheRoom() {
        #expect(OutlineColumn.width(forRoom: 400) == 220)
        #expect(OutlineColumn.width(forRoom: 214) == 150)
        #expect(OutlineColumn.width(forRoom: 204) == 140)
        #expect(OutlineColumn.width(forRoom: 200) == nil)
        #expect(OutlineColumn.width(forRoom: 0) == nil)
    }

    // MARK: - ⌥Tab

    private func optionTab() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: 48
        ))
    }

    /// SwiftUI's View menu item carries ⌥Tab as its key equivalent.
    @Test
    func viewMenuItemIsOptionTab() throws {
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        let menu = try #require(NSApp.mainMenu)
        let item = try #require(items(menu).first { $0.title == "Show Outline" || $0.title == "Hide Outline" })
        #expect(item.keyEquivalent == "\t")
        #expect(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .option)
    }

    /// AppKit matches an ⌥Tab key-down against a menu item with that
    /// equivalent.
    @Test
    func menuMatchesOptionTab() throws {
        final class Target: NSObject {
            var fired = 0
            @objc func fire(_ sender: Any?) { fired += 1 }
        }
        let target = Target()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Show Outline", action: #selector(Target.fire(_:)), keyEquivalent: "\t")
        item.keyEquivalentModifierMask = .option
        item.target = target
        menu.addItem(item)
        #expect(menu.performKeyEquivalent(with: try optionTab()))
        #expect(target.fired == 1)
    }

    /// Should ⌥Tab reach the text view, its standard binding
    /// (`insertTabIgnoringFieldEditor:`) toggles the outline and types
    /// nothing.
    @Test
    func optionTabInTheTextViewTogglesInsteadOfTyping() throws {
        let (_, textView) = makeEditor("- item\n")
        var toggles = 0
        textView.toggleOutline = { toggles += 1 }
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        textView.interpretKeyEvents([try optionTab()])
        #expect(toggles == 1)
        #expect(textView.string == "- item\n")
    }
}
