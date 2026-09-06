import AppKit
import Testing
@testable import Paper

/// Return inside a list item starts the next item; Return on an empty item
/// removes its marker; everywhere else Return is a plain newline.
@MainActor
struct ListContinuationTests {
    private func returnPressed(in text: String, at selection: NSRange) -> (String, NSRange)? {
        guard let edit = ListContinuation.edit(in: text as NSString, selection: selection) else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        return (result, edit.selection)
    }

    @Test
    func continuesADashedItem() {
        let (text, selection) = returnPressed(in: "- first", at: NSRange(location: 7, length: 0))!
        #expect(text == "- first\n- ")
        #expect(selection == NSRange(location: 10, length: 0))
    }

    @Test
    func continuesWithTheItemIndentAndGap() {
        let (text, _) = returnPressed(in: "  *   deep", at: NSRange(location: 10, length: 0))!
        #expect(text == "  *   deep\n  *   ", "indent and marker gap carry over")
    }

    @Test
    func numbersCountUp() {
        let (text, _) = returnPressed(in: "1. one\n2. two", at: NSRange(location: 13, length: 0))!
        #expect(text == "1. one\n2. two\n3. ")
        let (paren, _) = returnPressed(in: "9) nine", at: NSRange(location: 7, length: 0))!
        #expect(paren == "9) nine\n10) ")
    }

    @Test
    func aLetterSuffixAdvancesTheLetter() {
        let (text, _) = returnPressed(in: "1a) Commercial society", at: NSRange(location: 22, length: 0))!
        #expect(text == "1a) Commercial society\n1b) ")
    }

    @Test
    func lettersAdvanceAndAnEmptyLetteredItemEndsTheList() {
        // #70
        let (text, _) = returnPressed(in: "a. first", at: NSRange(location: 8, length: 0))!
        #expect(text == "a. first\nb. ")
        let (paren, _) = returnPressed(in: "  B) second", at: NSRange(location: 11, length: 0))!
        #expect(paren == "  B) second\n  C) ")
        let (ended, selection) = returnPressed(in: "a. first\nb. ", at: NSRange(location: 12, length: 0))!
        #expect(ended == "a. first\n")
        #expect(selection == NSRange(location: 9, length: 0))
        #expect(returnPressed(in: "a.m. call", at: NSRange(location: 9, length: 0)) == nil, "an abbreviation is prose")
    }

    @Test
    func continuesInsideABlockQuote() {
        let (text, _) = returnPressed(in: "> - quoted item", at: NSRange(location: 15, length: 0))!
        #expect(text == "> - quoted item\n> - ")
    }

    @Test
    func returnMidItemSplitsIntoANewItem() {
        let (text, selection) = returnPressed(in: "- one two", at: NSRange(location: 5, length: 0))!
        #expect(text == "- one\n- two", "the tail becomes the next item's text")
        #expect(selection == NSRange(location: 8, length: 0))
    }

    private func tabbed(
        in text: String, at selection: NSRange, outdent: Bool = false
    ) -> (text: String, selection: NSRange)? {
        guard let edit = ListContinuation.indent(in: text as NSString, selection: selection, outdent: outdent)
        else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        return (result, edit.selection)
    }

    @Test
    func tabIndentsTheWholeItemFromAnywhereInIt() {
        let (text, selection) = tabbed(in: "- one\n- two", at: NSRange(location: 11, length: 0))!
        #expect(text == "- one\n  - two", "the marker moves, not the text after the caret")
        #expect(selection == NSRange(location: 13, length: 0))
    }

    @Test
    func tabIndentsAFreshlyContinuedEmptyItem() {
        let (text, selection) = tabbed(in: "- one\n- ", at: NSRange(location: 8, length: 0))!
        #expect(text == "- one\n  - ")
        #expect(selection == NSRange(location: 10, length: 0))
    }

    @Test
    func shiftTabOutdentsSpacesOrATab() {
        let (spaced, selection) = tabbed(in: "  - two", at: NSRange(location: 7, length: 0), outdent: true)!
        #expect(spaced == "- two")
        #expect(selection == NSRange(location: 5, length: 0))
        let (tabby, _) = tabbed(in: "\t- two", at: NSRange(location: 6, length: 0), outdent: true)!
        #expect(tabby == "- two")
    }

    @Test
    func tabOutsideAListAndOutdentAtTheMarginAreOrdinary() {
        #expect(tabbed(in: "plain text", at: NSRange(location: 5, length: 0)) == nil)
        #expect(tabbed(in: "- two", at: NSRange(location: 5, length: 0), outdent: true) == nil,
                "nothing left to outdent")
    }

    @Test
    func returnOnAnEmptyItemRemovesTheMarker() {
        let (text, selection) = returnPressed(in: "- one\n- ", at: NSRange(location: 8, length: 0))!
        #expect(text == "- one\n")
        #expect(selection == NSRange(location: 6, length: 0))
    }

    @Test
    func plainParagraphsAreLeftToTheDefault() {
        #expect(returnPressed(in: "no list here", at: NSRange(location: 12, length: 0)) == nil)
        #expect(returnPressed(in: "", at: NSRange(location: 0, length: 0)) == nil)
    }

    @Test
    func caretInsideTheMarkerIsLeftToTheDefault() {
        #expect(returnPressed(in: "- item", at: NSRange(location: 0, length: 0)) == nil)
        #expect(returnPressed(in: "- item", at: NSRange(location: 1, length: 0)) == nil)
    }

    @Test
    func textViewReturnContinuesAndUndoes() {
        let textView = PaperTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let host = TestUndoHost()
        host.attach(to: textView)
        textView.string = "- first"
        textView.syntaxStyler.apply(to: textView)
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        textView.insertNewline(nil)
        #expect(textView.string == "- first\n- ")
        #expect(textView.selectedRange() == NSRange(location: 10, length: 0))
        host.undoManager.undo()
        #expect(textView.string == "- first")
    }

    @Test
    func textViewReturnOnEmptyItemEndsTheList() {
        let textView = PaperTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let host = TestUndoHost()
        host.attach(to: textView)
        textView.string = "- first\n- "
        textView.syntaxStyler.apply(to: textView)
        textView.setSelectedRange(NSRange(location: 10, length: 0))
        textView.insertNewline(nil)
        #expect(textView.string == "- first\n")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 0))
    }
}
