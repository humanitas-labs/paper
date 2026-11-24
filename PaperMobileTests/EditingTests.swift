import Testing
import UIKit
@testable import Paper

/// Editing on the iOS page, driven through UIKit's text input as typing is.
@MainActor
struct EditingTests {
    private func makeEditor(_ source: String, caret: Int? = nil) throws -> (UIWindow, MobileTextView, Box) {
        let (window, textView) = try RenderProbeTests.makeWindow(size: CGSize(width: 402, height: 874), style: .light)
        textView.load(source)
        let box = Box(text: source)
        textView.onTextChange = { box.text = $0 }
        _ = textView.becomeFirstResponder()
        textView.selectedRange = NSRange(location: caret ?? source.utf16.count, length: 0)
        return (window, textView, box)
    }

    final class Box { var text: String; init(text: String) { self.text = text } }

    /// Lets the run loop turn, for the substitutions scheduled after a key.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(50)) }

    @Test
    func returnContinuesAList() throws {
        let (window, textView, box) = try makeEditor("- one")
        defer { window.isHidden = true }
        textView.insertText("\n")
        #expect(textView.text == "- one\n- ")
        #expect(box.text == "- one\n- ")
        #expect(textView.selectedRange == NSRange(location: 8, length: 0))
    }

    @Test
    func returnOnAnEmptyItemEndsTheList() throws {
        let (window, textView, _) = try makeEditor("- one\n- ")
        defer { window.isHidden = true }
        textView.insertText("\n")
        #expect(!textView.text.hasSuffix("- "))
    }

    @Test
    func backspaceAtTheStartOfAnItemRemovesItsPrefix() throws {
        let (window, textView, box) = try makeEditor("- one", caret: 2)
        defer { window.isHidden = true }
        textView.deleteBackward()
        #expect(textView.text == "one")
        #expect(box.text == "one")
    }

    @Test
    func theCaretNeverRestsInsideAListPrefix() throws {
        let (window, textView, _) = try makeEditor("- one", caret: 5)
        defer { window.isHidden = true }
        textView.selectedRange = NSRange(location: 1, length: 0)
        #expect(textView.selectedRange.location != 1)
    }

    @Test
    func typedArrowAndDashesAreSubstituted() async throws {
        let (window, textView, _) = try makeEditor("a -")
        defer { window.isHidden = true }
        textView.insertText(">")
        try await settle()
        #expect(textView.text == "a →")
        textView.insertText(" b --")
        textView.insertText(" ")
        try await settle()
        #expect(textView.text == "a → b — ")
    }

    @Test
    func typedBracketsStartATask() async throws {
        let (window, textView, _) = try makeEditor("[")
        defer { window.isHidden = true }
        textView.insertText("]")
        try await settle()
        #expect(textView.text == "- [ ] ")
    }

    @Test
    func aTapOnATaskCircleChecksIt() throws {
        let (window, textView, box) = try makeEditor("- [ ] Buy milk\n\nAfter", caret: 21)
        defer { window.isHidden = true }
        textView.layoutIfNeeded()
        var prefix = NSRange()
        _ = textView.textStorage.attribute(.taskBox, at: 0, longestEffectiveRange: &prefix,
                                           in: NSRange(location: 0, length: textView.textStorage.length))
        let circle = try #require(DecorationView.taskCircleRect(
            forPrefix: prefix, layoutManager: textView.paperLayoutManager, storage: textView.textStorage
        ))
        let origin = textView.textContainerOrigin
        let point = CGPoint(x: circle.midX + origin.x, y: circle.midY + origin.y)
        let action = try #require(textView.tapAction(at: point))
        textView.perform(action)
        #expect(textView.text == "- [x] Buy milk\n\nAfter")
        #expect(box.text == textView.text)
        // The caret stays where it was.
        #expect(textView.selectedRange == NSRange(location: 21, length: 0))
    }

    @Test
    func theCaretRevealsItsParagraphOnly() throws {
        let (window, textView, _) = try makeEditor("Some **bold**\n\nOther **bold**", caret: 2)
        defer { window.isHidden = true }
        let layoutManager = textView.paperLayoutManager
        #expect(!layoutManager.isConcealed(characterAt: 5))
        #expect(layoutManager.isConcealed(characterAt: 21))
        _ = textView.resignFirstResponder()
        #expect(layoutManager.isConcealed(characterAt: 5))
    }

    @Test
    func editsChangeOnlyWhatWasTyped() throws {
        let source = try String(contentsOf: RenderProbeTests.fixtureURL, encoding: .utf8)
        let (window, textView, box) = try makeEditor(source, caret: 2)
        defer { window.isHidden = true }
        textView.insertText("X")
        var expected = source
        expected.insert("X", at: expected.index(expected.startIndex, offsetBy: 2))
        #expect(box.text == expected)
        #expect(MarkdownDocument(text: box.text).data == Data(expected.utf8))
    }

    @Test
    func aTapOnATableCellLandsInItsSource() throws {
        let source = "| A | B |\n|---|---|\n| left | right |\n\nAfter"
        let (window, textView, _) = try makeEditor(source, caret: source.utf16.count)
        defer { window.isHidden = true }
        textView.layoutIfNeeded()
        let layoutManager = textView.paperLayoutManager
        let rowStart = (source as NSString).range(of: "| left").location
        let glyph = layoutManager.glyphIndexForCharacter(at: rowStart)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let origin = textView.textContainerOrigin
        // Far right of the row: the second column.
        let point = CGPoint(x: origin.x + fragment.minX + 250, y: origin.y + fragment.midY)
        let index = try #require(textView.tableSourceIndex(at: point))
        let rightRange = (source as NSString).range(of: "right")
        #expect(index >= rightRange.location - 1 && index <= NSMaxRange(rightRange))
    }
}

@MainActor
struct KeyboardRowTests {
    private func makeEditor(_ source: String, caret: Int) throws -> (UIWindow, MobileTextView) {
        let (window, textView) = try RenderProbeTests.makeWindow(size: CGSize(width: 402, height: 874), style: .light)
        textView.load(source)
        _ = textView.becomeFirstResponder()
        textView.selectedRange = NSRange(location: caret, length: 0)
        return (window, textView)
    }

    @Test
    func boldWrapsTheWordAtTheCaret() throws {
        let (window, textView) = try makeEditor("make this bold", caret: 11)
        defer { window.isHidden = true }
        textView.toggle(.bold)
        #expect(textView.text == "make this **bold**")
    }

    @Test
    func theTaskKeyStartsFlipsAndConvertsTasks() throws {
        let (window, textView) = try makeEditor("Buy milk", caret: 3)
        defer { window.isHidden = true }
        textView.toggleTaskLine()
        #expect(textView.text == "- [ ] Buy milk")
        textView.toggleTaskLine()
        #expect(textView.text == "- [x] Buy milk")
        textView.load("- Buy milk")
        textView.selectedRange = NSRange(location: 5, length: 0)
        textView.toggleTaskLine()
        #expect(textView.text == "- [ ] Buy milk")
    }

    @Test
    func indentAndOutdentMoveAListItem() throws {
        let (window, textView) = try makeEditor("- one\n- two", caret: 11)
        defer { window.isHidden = true }
        #expect(textView.indentListItem(outdent: false))
        #expect(textView.text.hasSuffix("\n  - two") || textView.text.hasSuffix("\n\t- two") || textView.text.hasSuffix("\n    - two"))
        #expect(textView.indentListItem(outdent: true))
        #expect(textView.text == "- one\n- two")
    }

    @Test
    func aLinkWrapsTheWordAndWaitsForTheAddress() throws {
        UIPasteboard.general.string = "not a url"
        let (window, textView) = try makeEditor("see docs here", caret: 6)
        defer { window.isHidden = true }
        textView.insertLink()
        #expect(textView.text == "see [docs]() here")
        #expect(textView.selectedRange == NSRange(location: 11, length: 0))
    }
}

@MainActor
struct CaretTests {
    private func caret(in source: String, at location: Int) throws -> (UIWindow, MobileTextView, CGRect) {
        let (window, textView) = try RenderProbeTests.makeWindow(size: CGSize(width: 402, height: 874), style: .light)
        textView.load(source)
        _ = textView.becomeFirstResponder()
        textView.selectedRange = NSRange(location: location, length: 0)
        textView.layoutIfNeeded()
        let position = try #require(textView.position(from: textView.beginningOfDocument, offset: location))
        return (window, textView, textView.caretRect(for: position))
    }

    /// The caret spans the font's ascent and descent around the baseline.
    private func expectOnBaseline(_ rect: CGRect, baseline: CGFloat, font: UIFont = Appearance.bodyFont()) {
        let overshoot = Appearance.caretOvershoot
        #expect(abs(rect.minY - (baseline - font.ascender - overshoot)) < 0.5)
        #expect(abs(rect.maxY - (baseline - font.descender + overshoot)) < 0.5)
    }

    @Test
    func theCaretAtAParagraphsEndStandsOnItsBaselineNotInTheSpacingBelow() throws {
        let source = "First paragraph\n\nSecond"
        let (window, textView, rect) = try caret(in: source, at: 15)
        defer { window.isHidden = true }
        let layoutManager = textView.paperLayoutManager
        let glyph = layoutManager.glyphIndexForCharacter(at: 14)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = textView.textContainerOrigin.y + fragment.minY + layoutManager.location(forGlyphAt: glyph).y
        expectOnBaseline(rect, baseline: baseline)
    }

    @Test
    func theCaretOnAnEmptyLineStandsWhereTypedTextWillSit() throws {
        let source = "Above\n\nBelow"
        let (window, textView, empty) = try caret(in: source, at: 6)
        defer { window.isHidden = true }
        // Type a letter there: the caret after it must sit at the same height.
        textView.insertText("x")
        textView.layoutIfNeeded()
        let position = try #require(textView.position(from: textView.beginningOfDocument, offset: 7))
        let typed = textView.caretRect(for: position)
        #expect(abs(empty.minY - typed.minY) < 0.5)
        #expect(abs(empty.maxY - typed.maxY) < 0.5)
    }

    @Test
    func theCaretAfterAFinalNewlineSitsOnTheNewLine() throws {
        let source = "Above\n"
        let (window, textView, empty) = try caret(in: source, at: 6)
        defer { window.isHidden = true }
        textView.insertText("x")
        textView.layoutIfNeeded()
        let position = try #require(textView.position(from: textView.beginningOfDocument, offset: 7))
        let typed = textView.caretRect(for: position)
        #expect(abs(empty.minY - typed.minY) < 1)
    }
}

@MainActor
struct KeyboardBarLayoutTests {
    /// Five buttons and half of a sixth show; the rest scroll into view.
    @Test func theBarScrollsWithFiveAndAHalfButtonsInView() throws {
        let (window, textView) = try RenderProbeTests.makeWindow(size: CGSize(width: 402, height: 874), style: .light)
        defer { window.isHidden = true }
        let bar = try #require(textView.inputAccessoryView)
        bar.frame = CGRect(x: 0, y: 0, width: 402, height: 58)
        bar.layoutIfNeeded()
        bar.layoutIfNeeded()
        func scroller(_ v: UIView) -> UIScrollView? {
            if let s = v as? UIScrollView { return s }
            for s in v.subviews { if let found = scroller(s) { return found } }
            return nil
        }
        let scroll = try #require(scroller(bar))
        let button = try #require(scroll.subviews.first?.subviews.first)
        let visible = scroll.bounds.width / button.bounds.width
        #expect(visible > 5.3 && visible < 5.7)
        #expect(scroll.contentSize.width > scroll.bounds.width)
    }
}
