import AppKit
import Testing
@testable import Paper

/// `- [ ]` and `- [x]` are task items: the marker and box conceal on every
/// paragraph and a circle the text view draws stands in their place; the
/// prefix is one unit for the caret; a done item's text recedes into the
/// quote ink; a click on the circle flips the source; Return continues the
/// task. The file keeps its source.
@MainActor
struct TaskListTests {
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

    @Test
    func openAndDoneItemsConcealTheirPrefixAndReserveTheCircle() throws {
        let text = "- [ ] open\n- [x] done\n- [X] also done\n- [y] not a task\n- [ ]x prose\n"
        let (textView, layoutManager) = makeTextView(text, selectedAt: text.utf16.count)
        let storage = try #require(textView.textStorage)

        // `- [ ] open`: dash, space, `[`, space, `]` conceal but for the
        // `[`, which reserves the circle's room.
        for index in [0, 1, 3, 4] {
            #expect(layoutManager.isConcealed(characterAt: index), "prefix character \(index) conceals")
        }
        #expect(!layoutManager.isConcealed(characterAt: 2))
        #expect(storage.attribute(.reservedWidth, at: 2, effectiveRange: nil) as? CGFloat == MarkdownSyntaxStyler.taskBoxReservedWidth)
        #expect(storage.attribute(.kern, at: 2, effectiveRange: nil) as? CGFloat == Appearance.letterSpacing, "no kern: the active line reads at its own width")
        #expect(storage.attribute(.taskBox, at: 0, effectiveRange: nil) as? String == "[ ]")
        #expect(storage.attribute(.taskBox, at: 4, effectiveRange: nil) as? String == "[ ]")
        #expect(storage.attribute(.taskBox, at: 6, effectiveRange: nil) == nil, "the text is not part of the box")

        // Done, either case: the box value carries the source and the text
        // takes the quote ink.
        let done = (text as NSString).range(of: "- [x] done")
        #expect(storage.attribute(.taskBox, at: done.location, effectiveRange: nil) as? String == "[x]")
        #expect(storage.attribute(.foregroundColor, at: done.location + 6, effectiveRange: nil) as? NSColor == Appearance.quoteInk)
        let upper = (text as NSString).range(of: "- [X] also done")
        #expect(storage.attribute(.taskBox, at: upper.location, effectiveRange: nil) as? String == "[X]")
        #expect(storage.attribute(.foregroundColor, at: upper.location + 6, effectiveRange: nil) as? NSColor == Appearance.quoteInk)
        #expect(storage.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor == Appearance.ink, "an open item keeps the ink")

        // Not tasks: a plain list item with its dash and literal brackets.
        for needle in ["- [y] not a task", "- [ ]x prose"] {
            let item = (text as NSString).range(of: needle)
            #expect(storage.attribute(.taskBox, at: item.location, effectiveRange: nil) == nil, Comment(rawValue: needle))
            #expect(storage.attribute(.glyphSubstitute, at: item.location, effectiveRange: nil) as? String == "–", Comment(rawValue: needle))
            #expect(!layoutManager.isConcealed(characterAt: item.location + 2), Comment(rawValue: needle))
        }

        // The hang reserves the circle: the text sits past the diameter
        // and the gap, not past a dash.
        let style = try #require(storage.attribute(.paragraphStyle, at: 6, effectiveRange: nil) as? NSParagraphStyle)
        let expected = Appearance.listIndent + Appearance.listMarkerGap + Appearance.taskBoxSize
            + (" " as NSString).size(withAttributes: [.font: Appearance.bodyFont()]).width
        #expect(abs(style.headIndent - expected) < 0.5)
        #expect(textView.string == text)
    }

    @Test
    func theActiveParagraphKeepsItsCircle() throws {
        let text = "- [ ] open *bold*\n- [x] done\n"
        let (textView, layoutManager) = makeTextView(text, selectedAt: 8)
        for index in [0, 1, 3, 4] {
            #expect(layoutManager.isConcealed(characterAt: index), "prefix character \(index) conceals on the active line")
        }
        #expect(!layoutManager.isConcealed(characterAt: 11), "the emphasis delimiter reveals as ever")
        #expect(layoutManager.isConcealed(characterAt: 18), "the other item stays rendered")
        let storage = try #require(textView.textStorage)
        #expect(storage.attribute(.taskBox, at: 0, effectiveRange: nil) as? String == "[ ]")

        // The text starts past the circle's room on the active line, as
        // it does off it.
        let textX = layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: 6)).x
        let boxX = layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: 2)).x
        let reserved = try #require(storage.attribute(.reservedWidth, at: 2, effectiveRange: nil) as? CGFloat)
        let font = try #require(storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)
        let kern = storage.attribute(.kern, at: 5, effectiveRange: nil) as? CGFloat ?? 0
        let space = (" " as NSString).size(withAttributes: [.font: font]).width + kern
        #expect(abs(textX - boxX - reserved - space) < 1)
    }

    @Test
    func theCaretTreatsThePrefixAsOneUnit() throws {
        let text = "above\n- [ ] open\n  - [x] nested\n"
        let (textView, _) = makeTextView(text, selectedAt: 12)
        func caret() -> NSRange { textView.selectedRange() }
        #expect(caret() == NSRange(location: 12, length: 0), "the caret at the text's start stays")

        textView.moveLeft(nil)
        #expect(caret() == NSRange(location: 6, length: 0), "Left hops the prefix")
        textView.moveRight(nil)
        #expect(caret() == NSRange(location: 12, length: 0), "Right hops it back")

        for inside in 7...11 {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.setSelectedRange(NSRange(location: inside, length: 0))
            #expect(caret() == NSRange(location: 12, length: 0), "a caret placed at \(inside) lands at the text's start")
        }

        textView.setSelectedRange(NSRange(location: 12, length: 0))
        textView.moveLeftAndModifySelection(nil)
        #expect(caret() == NSRange(location: 6, length: 6), "Shift-Left selects the prefix whole")
        textView.setSelectedRange(NSRange(location: 9, length: 5))
        #expect(caret() == NSRange(location: 6, length: 8), "a selection reaching into the prefix takes it whole")
        textView.setSelectedRange(NSRange(location: 2, length: 7))
        #expect(caret() == NSRange(location: 2, length: 10))

        // The nested item's indent is outside the unit: the caret sits
        // between indent and marker, and Left from the text goes there.
        let nested = (text as NSString).range(of: "  - [x] nested")
        textView.setSelectedRange(NSRange(location: nested.location + 8, length: 0))
        textView.moveLeft(nil)
        #expect(caret() == NSRange(location: nested.location + 2, length: 0))
        textView.moveLeft(nil)
        #expect(caret() == NSRange(location: nested.location + 1, length: 0), "then the indent, a character at a time")

        // Up from the text's start of the nested item lands on the open
        // item's text, never inside its prefix.
        textView.setSelectedRange(NSRange(location: nested.location + 8, length: 0))
        textView.moveUp(nil)
        #expect(caret().length == 0)
        #expect(caret().location == 6 || caret().location >= 12, "up never lands inside the prefix")
    }

    @Test
    func plainAndOrderedItemsAreUnitsToo() throws {
        let text = "- dash\n1. one\nb) two\n> * quoted\n"
        let (textView, _) = makeTextView(text, selectedAt: 2)
        func caret() -> NSRange { textView.selectedRange() }
        textView.moveLeft(nil)
        #expect(caret() == NSRange(location: 0, length: 0), "Left from the text hops the dash and its gap")
        textView.moveRight(nil)
        #expect(caret() == NSRange(location: 2, length: 0))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(caret() == NSRange(location: 2, length: 0), "a caret between marker and gap lands at the text")

        let one = (text as NSString).range(of: "1. one")
        textView.setSelectedRange(NSRange(location: one.location + 3, length: 0))
        textView.moveLeft(nil)
        #expect(caret() == NSRange(location: one.location, length: 0), "`1. ` is one unit")
        textView.setSelectedRange(NSRange(location: one.location + 3, length: 0))
        textView.moveLeftAndModifySelection(nil)
        #expect(caret() == NSRange(location: one.location, length: 3))

        // A lettered prefix is a unit like a numbered one (#70).
        let lettered = (text as NSString).range(of: "b) two")
        textView.setSelectedRange(NSRange(location: lettered.location + 3, length: 0))
        textView.moveLeft(nil)
        #expect(caret() == NSRange(location: lettered.location, length: 0), "`b) ` is one unit")
        textView.setSelectedRange(NSRange(location: lettered.location + 1, length: 0))
        #expect(caret() == NSRange(location: lettered.location + 3, length: 0), "a caret inside it lands at the text")

        // The quote prefix is outside the unit.
        let quoted = (text as NSString).range(of: "> * quoted")
        textView.setSelectedRange(NSRange(location: quoted.location + 4, length: 0))
        textView.moveLeft(nil)
        #expect(caret() == NSRange(location: quoted.location + 2, length: 0))

        // Backspace at the text's start un-lists the item and keeps the
        // quote.
        let host = TestUndoHost()
        host.attach(to: textView)
        host.undoManager.groupsByEvent = false
        textView.setSelectedRange(NSRange(location: quoted.location + 4, length: 0))
        host.undoManager.beginUndoGrouping()
        textView.deleteBackward(nil)
        host.undoManager.endUndoGrouping()
        #expect(textView.string == "- dash\n1. one\nb) two\n> quoted\n")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        host.undoManager.beginUndoGrouping()
        textView.deleteBackward(nil)
        host.undoManager.endUndoGrouping()
        #expect(textView.string == "dash\n1. one\nb) two\n> quoted\n")
        host.undoManager.undo()
        host.undoManager.undo()
        #expect(textView.string == text)
    }

    @Test
    func backspaceAtTheTextStartRemovesThePrefixAndDeleteBeforeItDoesNothing() throws {
        let text = "- [ ] open\n  - [x] nested\n"
        let (textView, _) = makeTextView(text, selectedAt: 6)
        let host = TestUndoHost()
        host.attach(to: textView)
        host.undoManager.groupsByEvent = false

        host.undoManager.beginUndoGrouping()
        textView.deleteBackward(nil)
        host.undoManager.endUndoGrouping()
        #expect(textView.string == "open\n  - [x] nested\n")
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
        host.undoManager.undo()
        #expect(textView.string == text, "one undo step gives the prefix back")

        // Nested: the indent stays.
        let nested = (text as NSString).range(of: "  - [x] nested")
        textView.setSelectedRange(NSRange(location: nested.location + 8, length: 0))
        host.undoManager.beginUndoGrouping()
        textView.deleteBackward(nil)
        host.undoManager.endUndoGrouping()
        #expect(textView.string == "- [ ] open\n  nested\n")
        host.undoManager.undo()
        #expect(textView.string == text)

        // Delete before the prefix is a no-op; before the indent it is
        // ordinary.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        host.undoManager.beginUndoGrouping()
        textView.deleteForward(nil)
        host.undoManager.endUndoGrouping()
        #expect(textView.string == text)
        textView.setSelectedRange(NSRange(location: nested.location, length: 0))
        host.undoManager.beginUndoGrouping()
        textView.deleteForward(nil)
        host.undoManager.endUndoGrouping()
        #expect(textView.string == "- [ ] open\n - [x] nested\n")

        // Backspace in the text is ordinary.
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        host.undoManager.beginUndoGrouping()
        textView.deleteBackward(nil)
        host.undoManager.endUndoGrouping()
        #expect(textView.string == "- [ ] pen\n - [x] nested\n")
    }

    @Test
    func nestedTasksIndentAsNestedItemsDo() throws {
        let text = "- [ ] top\n  - [ ] nested\n- item\n  - nested item\n"
        let (textView, _) = makeTextView(text, selectedAt: text.utf16.count)
        let storage = try #require(textView.textStorage)
        func style(at index: Int) throws -> NSParagraphStyle {
            try #require(storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
        }
        let nestedTask = (text as NSString).range(of: "  - [ ] nested").location
        let nestedItem = (text as NSString).range(of: "  - nested item").location
        #expect(try style(at: 0).firstLineHeadIndent == Appearance.listIndent)
        #expect(try style(at: nestedTask).firstLineHeadIndent == style(at: nestedItem).firstLineHeadIndent)
        #expect(try style(at: 0).firstLineHeadIndent == style(at: nestedTask).firstLineHeadIndent - Appearance.listNestIndent
                + ("  " as NSString).size(withAttributes: [.font: Appearance.bodyFont()]).width, "one nesting step apart")
    }

    @Test
    func aClickOnTheCircleFlipsTheSourceUndoablyAndLeavesTheCaret() throws {
        let text = "- [ ] open\n- [x] done\n"
        let (textView, layoutManager) = makeTextView(text, selectedAt: text.utf16.count)
        let host = TestUndoHost()
        host.attach(to: textView)

        // The circle sits where the `[` renders, on the first line.
        func circlePoint(forCharacterAt index: Int) -> NSPoint {
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = layoutManager.location(forGlyphAt: glyph)
            let origin = textView.textContainerOrigin
            return NSPoint(
                x: origin.x + fragment.minX + location.x + Appearance.taskBoxSize / 2,
                y: origin.y + fragment.minY + location.y - Appearance.bodyFont().capHeight / 2
            )
        }

        // Each click is its own event, and so its own undo group, in the
        // app; here the groups are opened and closed by hand.
        host.undoManager.groupsByEvent = false
        host.undoManager.beginUndoGrouping()
        #expect(textView.toggleTaskBox(at: circlePoint(forCharacterAt: 2)))
        host.undoManager.endUndoGrouping()
        #expect(textView.string == "- [x] open\n- [x] done\n")
        #expect(textView.selectedRange() == NSRange(location: text.utf16.count, length: 0), "the caret stays put")
        textView.syntaxStyler.apply(to: textView)
        layoutManager.ensureLayout(for: textView.textContainer!)
        host.undoManager.beginUndoGrouping()
        #expect(textView.toggleTaskBox(at: circlePoint(forCharacterAt: 13)))
        host.undoManager.endUndoGrouping()
        #expect(textView.string == "- [x] open\n- [ ] done\n")

        host.undoManager.undo()
        #expect(textView.string == "- [x] open\n- [x] done\n")
        host.undoManager.undo()
        #expect(textView.string == text, "each flip is its own undo step")

        // Undo leaves the caret on the edited line; move it off so the
        // items render again.
        textView.syntaxStyler.apply(to: textView)
        textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        layoutManager.ensureLayout(for: textView.textContainer!)

        // Off the circle, and on the text, nothing happens.
        var beside = circlePoint(forCharacterAt: 2)
        beside.x += Appearance.taskBoxSize * 3
        #expect(!textView.toggleTaskBox(at: beside))
        #expect(textView.string == text)

        // The text starts where the reserved room ends, and the `[` takes
        // that room in the layout.
        // Measured from what the storage carries, not the live
        // configuration, which other suites change under this one.
        let storage = try #require(textView.textStorage)
        let textX = layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: 6)).x
        let boxX = layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: 2)).x
        let reserved = try #require(storage.attribute(.reservedWidth, at: 2, effectiveRange: nil) as? CGFloat)
        let font = try #require(storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)
        let kern = storage.attribute(.kern, at: 5, effectiveRange: nil) as? CGFloat ?? 0
        let space = (" " as NSString).size(withAttributes: [.font: font]).width + kern
        #expect(abs(textX - boxX - reserved - space) < 1)

        // The circle is there on the active paragraph too, and a click on
        // it flips the item without moving the caret.
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        layoutManager.ensureLayout(for: textView.textContainer!)
        host.undoManager.beginUndoGrouping()
        #expect(textView.toggleTaskBox(at: circlePoint(forCharacterAt: 2)))
        host.undoManager.endUndoGrouping()
        #expect(textView.string == "- [x] open\n- [x] done\n")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 0))
    }

    @Test
    func typingBracketsAtTheStartOfALineMakesATask() throws {
        func typed(_ text: String, then character: String = "]") -> (String, Int) {
            let textView = PaperTextView()
            textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            textView.string = text
            textView.syntaxStyler.apply(to: textView)
            textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            textView.insertText(character, replacementRange: NSRange(location: text.utf16.count, length: 0))
            textView.flushPendingSubstitution()
            return (textView.string, textView.selectedRange().location)
        }
        #expect(typed("[") == ("- [ ] ", 6), "brackets alone start a task list")
        #expect(typed("- [") == ("- [ ] ", 6), "brackets after a marker complete it")
        #expect(typed("  [") == ("  - [ ] ", 8), "the indent carries, so the task nests")
        #expect(typed("> [") == ("> - [ ] ", 8))
        #expect(typed("1. [") == ("1. [ ] ", 7))
        #expect(typed("a. [") == ("a. [ ] ", 7), "a lettered item takes a box too (#70)")
        #expect(typed("first\n[") == ("first\n- [ ] ", 12), "only the line's own start counts")
        #expect(typed("see [") == ("see []", 6), "mid-line brackets are prose")
        #expect(typed("- [x] [") == ("- [x] []", 8), "a second pair on a task is prose")
        #expect(typed("`[") == ("`[]", 3), "not in code")

        // One undo step gives back the typed pair.
        let textView = PaperTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let host = TestUndoHost()
        host.attach(to: textView)
        host.undoManager.groupsByEvent = false
        textView.string = "["
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        host.undoManager.beginUndoGrouping()
        textView.insertText("]", replacementRange: NSRange(location: 1, length: 0))
        host.undoManager.endUndoGrouping()
        host.undoManager.beginUndoGrouping()
        textView.flushPendingSubstitution()
        host.undoManager.endUndoGrouping()
        #expect(textView.string == "- [ ] ")
        host.undoManager.undo()
        #expect(textView.string == "[]")
    }

    @Test
    func returnContinuesATaskAndClearsAnEmptyOne() {
        func returned(_ text: String, at location: Int) -> String? {
            guard let edit = ListContinuation.edit(in: text as NSString, selection: NSRange(location: location, length: 0)) else { return nil }
            return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        }
        #expect(returned("- [ ] first", at: 11) == "- [ ] first\n- [ ] ")
        #expect(returned("- [x] done", at: 10) == "- [x] done\n- [ ] ", "the next item starts open")
        #expect(returned("  - [ ]  wide", at: 13) == "  - [ ]  wide\n  - [ ]  ", "indent and gaps carry over")
        #expect(returned("- [ ] ", at: 6) == "", "Return on an empty task ends the list")
        #expect(returned("- [ ]", at: 5) == "", "so does one with no trailing space")
        #expect(returned("- [ ] first", at: 3) == nil, "Return inside the box is a plain newline")
    }

    @Test
    func aNestedTaskIsTheOneWithIndentBeforeItsMarker() {
        let text = "- [ ] top\n  - [x] nested\n\t- [ ] tabbed\n- [ ] top again\n" as NSString
        #expect(!PaperTextView.isNestedTask(prefixAt: 0, in: text))
        #expect(PaperTextView.isNestedTask(prefixAt: text.range(of: "- [x]").location, in: text))
        #expect(PaperTextView.isNestedTask(prefixAt: text.range(of: "- [ ] tabbed").location, in: text))
        #expect(!PaperTextView.isNestedTask(prefixAt: text.range(of: "- [ ] top again").location, in: text))
    }
}
