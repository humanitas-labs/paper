import AppKit
import Testing
@testable import Paper

/// The restyle after an edit covers only the chunk around it. These tests
/// make that safe: every edit below is applied through the text view,
/// restyled incrementally, and compared attribute for attribute with a
/// fresh full pass over the same text. A wrong chunk rule fails here, not
/// on someone's screen.
@MainActor
struct IncrementalStyleTests {
    static let document = """
    # Heading one

    The quick brown fox jumps over the lazy dog with **bold**, *italic*, `code`, a [link](https://example.com), and a -> arrow.
    Second line of the same paragraph, ~~struck~~ and <u>underlined</u>.

    - item one with **bold**
      wrapped continuation of item one
    - item two

    - alpha
    - [ ] task open
    - [x] task done with *emphasis*
    1. ordered one
    2. ordered two

    > A quote line with `code` and **bold**
    > that continues on a second line.

    Plain paragraph between the blocks, before the fence.

    ```swift
    let x = 1  // not *italic*
    func f() -> Int { x }
    ```

    $$
    \\frac{a}{b} + c
    $$

    ---

    ![missing picture](images/none.png)

    A paragraph with a <!-- note --> comment inside it.

    ~~~
    an unterminated fence, so everything after it is prose
    - still a list item

    ## Heading two

    Last paragraph, then nothing.
    """

    private func makeEditor(_ text: String, documentURL: URL? = nil) -> PaperTextView {
        let textView = PaperTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 1120, height: 800)
        textView.documentURL = documentURL
        textView.string = text
        textView.syntaxStyler.apply(to: textView)
        return textView
    }

    /// Edits find their place by a marker string; one an earlier edit
    /// removed (the cumulative test) is skipped.
    private func location(of marker: String, in textView: PaperTextView, offset: Int = 0) -> Int? {
        let range = (textView.string as NSString).range(of: marker)
        guard range.location != NSNotFound else { return nil }
        return range.location + offset
    }

    private func insert(_ string: String, at location: Int?, in textView: PaperTextView) {
        guard let location else { return }
        textView.insertText(string, replacementRange: NSRange(location: location, length: 0))
    }

    private func replace(_ marker: String, with string: String, in textView: PaperTextView) {
        let range = (textView.string as NSString).range(of: marker)
        guard range.location != NSNotFound else { return }
        textView.insertText(string, replacementRange: range)
    }

    /// The edited view's storage must equal a fresh full pass over its text.
    private func expectMatchesFullPass(_ textView: PaperTextView, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        let fresh = makeEditor(textView.string, documentURL: textView.documentURL)
        let edited = textView.textStorage!
        let full = fresh.textStorage!
        #expect(edited.isEqual(to: full), comment, sourceLocation: sourceLocation)
        if !edited.isEqual(to: full) {
            // Point at the first differing run for the failure message.
            var index = 0
            while index < min(edited.length, full.length) {
                var a = NSRange(), b = NSRange()
                let attributesA = edited.attributes(at: index, effectiveRange: &a) as NSDictionary
                let attributesB = full.attributes(at: index, effectiveRange: &b) as NSDictionary
                if !attributesA.isEqual(attributesB) || a != b {
                    let line = (edited.string as NSString).substring(with: (edited.string as NSString).paragraphRange(for: NSRange(location: index, length: 0)))
                    Issue.record("first difference at \(index) in \(line.debugDescription): \(attributesA) vs \(attributesB)", sourceLocation: sourceLocation)
                    break
                }
                index = max(NSMaxRange(a), NSMaxRange(b))
            }
        }
    }

    struct Edit: CustomTestStringConvertible, Sendable {
        let name: String
        let local: Bool?
        let perform: @MainActor @Sendable (IncrementalStyleTests, PaperTextView) -> Void
        var testDescription: String { name }
    }

    nonisolated static let edits: [Edit] = [
        Edit(name: "type in a paragraph", local: true) { t, v in t.insert("x", at: t.location(of: "quick", in: v, offset: 5), in: v) },
        Edit(name: "open a bold run", local: true) { t, v in t.insert("**", at: t.location(of: "brown", in: v), in: v) },
        Edit(name: "close the bold run", local: true) { t, v in t.insert("**", at: t.location(of: "brown", in: v, offset: 5), in: v) },
        Edit(name: "blank a continuation line", local: true) { t, v in t.replace("  wrapped continuation of item one", with: "", in: v) },
        Edit(name: "fill the blank line between two lists", local: true) { t, v in t.insert("z", at: t.location(of: "\n\n- alpha", in: v, offset: 1), in: v) },
        Edit(name: "join two chunks", local: true) { t, v in t.replace("item two\n\n- alpha", with: "item two\n- alpha", in: v) },
        Edit(name: "split a chunk", local: true) { t, v in t.replace("- item two\n", with: "- item two\n\n", in: v) },
        Edit(name: "toggle a task", local: true) { t, v in t.replace("[ ]", with: "[x]", in: v) },
        Edit(name: "remove a heading marker", local: true) { t, v in t.replace("# Heading one", with: "Heading one", in: v) },
        Edit(name: "type inside the fence", local: true) { t, v in t.insert("y", at: t.location(of: "let x", in: v, offset: 3), in: v) },
        Edit(name: "type on the fence line", local: nil) { t, v in t.insert("!", at: t.location(of: "```swift", in: v, offset: 8), in: v) },
        Edit(name: "open a fence that stays unterminated", local: true) { t, v in t.insert("```\n", at: t.location(of: "Plain paragraph", in: v), in: v) },
        Edit(name: "close the unterminated fence", local: true) { t, v in t.insert("~~~\n", at: t.location(of: "## Heading two", in: v), in: v) },
        Edit(name: "delete the closing fence", local: true) { t, v in t.replace("func f() -> Int { x }\n```", with: "func f() -> Int { x }", in: v) },
        Edit(name: "open a comment", local: nil) { t, v in t.insert("<!-- ", at: t.location(of: "Second line", in: v), in: v) },
        Edit(name: "type inside the comment", local: true) { t, v in t.insert("!", at: t.location(of: "note", in: v, offset: 2), in: v) },
        Edit(name: "delete the comment's closer", local: nil) { t, v in t.replace(" -->", with: "", in: v) },
        Edit(name: "type inside display math", local: true) { t, v in t.insert("^2", at: t.location(of: "+ c", in: v, offset: 3), in: v) },
        Edit(name: "delete display math's closer", local: true) { t, v in t.replace("+ c\n$$", with: "+ c", in: v) },
        Edit(name: "close display math on its opening line", local: true) { t, v in t.replace("$$\n\\frac", with: "$$ x $$\n\\frac", in: v) },
        Edit(name: "type after an arrow", local: true) { t, v in t.insert(">", at: t.location(of: "-> arrow", in: v, offset: 2), in: v) },
        Edit(name: "paste three paragraphs", local: true) { t, v in t.insert("Pasted A\n\n- pasted item\n  wrapped\n\n> pasted quote\n\n", at: t.location(of: "Plain paragraph", in: v), in: v) },
        Edit(name: "paste a fenced block", local: true) { t, v in t.insert("```\ncode\n```\n\n", at: t.location(of: "Plain paragraph", in: v), in: v) },
        Edit(name: "storage replacement, as undo does it", local: true) { t, v in
            v.textStorage!.replaceCharacters(in: NSRange(location: t.location(of: "lazy", in: v)!, length: 4), with: "sleepy")
        },
        Edit(name: "type at the start", local: true) { t, v in t.insert("> ", at: 0, in: v) },
        Edit(name: "type at the end", local: true) { t, v in t.insert("\n- tail item", at: v.string.utf16.count, in: v) },
        Edit(name: "delete everything", local: nil) { t, v in v.insertText("", replacementRange: NSRange(location: 0, length: v.string.utf16.count)) },
        Edit(name: "replace everything", local: nil) { t, v in v.insertText("# New\n\n- one", replacementRange: NSRange(location: 0, length: v.string.utf16.count)) },
        Edit(name: "delete a whole list", local: true) { t, v in t.replace("- alpha\n- [ ] task open\n- [x] task done with *emphasis*\n1. ordered one\n2. ordered two\n", with: "", in: v) },
        Edit(name: "break a quote's continuation", local: true) { t, v in t.replace("> that continues", with: "that continues", in: v) },
        Edit(name: "make a thematic break", local: true) { t, v in t.replace("Plain paragraph between the blocks, before the fence.", with: "***", in: v) },
    ]

    @Test(arguments: edits)
    func anEditRestylesToWhatTheFullPassWouldSet(edit: Edit) {
        let textView = makeEditor(Self.document)
        edit.perform(self, textView)
        textView.syntaxStyler.applyEdited(to: textView)
        expectMatchesFullPass(textView, "after \(edit.name)")
        if let local = edit.local {
            #expect(textView.syntaxStyler.lastPassWasFull == !local, "\(edit.name) should take the \(local ? "local" : "full") path")
        }
    }

    @Test func editsAccumulateAcrossPasses() {
        let textView = makeEditor(Self.document)
        for edit in Self.edits.prefix(12) {
            edit.perform(self, textView)
            textView.syntaxStyler.applyEdited(to: textView)
            expectMatchesFullPass(textView, "after \(edit.name), cumulatively")
        }
    }

    @Test func twoEditsBeforeAPassTakeTheFullPath() {
        let textView = makeEditor(Self.document)
        insert("a", at: location(of: "quick", in: textView), in: textView)
        insert("b", at: location(of: "Last paragraph", in: textView), in: textView)
        textView.syntaxStyler.applyEdited(to: textView)
        #expect(textView.syntaxStyler.lastPassWasFull)
        expectMatchesFullPass(textView, "after two edits")
    }

    @Test func anImageBandComesAndGoesLocally() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paper-incremental-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("pic.png"))
        let textView = makeEditor(Self.document, documentURL: directory.appendingPathComponent("doc.md"))

        insert("![pic](pic.png)\n\n", at: location(of: "Plain paragraph", in: textView), in: textView)
        textView.syntaxStyler.applyEdited(to: textView)
        #expect(!textView.syntaxStyler.lastPassWasFull)
        expectMatchesFullPass(textView, "after adding an image")
        var bands = 0
        textView.textStorage!.enumerateAttribute(.imageSource, in: NSRange(location: 0, length: textView.textStorage!.length)) { value, _, _ in
            if value != nil { bands += 1 }
        }
        #expect(bands == 1)

        replace("![pic](pic.png)\n\n", with: "", in: textView)
        textView.syntaxStyler.applyEdited(to: textView)
        #expect(!textView.syntaxStyler.lastPassWasFull)
        expectMatchesFullPass(textView, "after removing the image")
    }

    @Test func chunkReachesTheBlankLinesEitherSide() {
        let text = "a\n\nb\nc\nd\n\ne\n" as NSString
        // Around `c`: one paragraph each way, then out to the blank lines.
        let chunk = MarkdownSyntaxStyler.chunk(around: NSRange(location: 5, length: 0), in: text)
        #expect(text.substring(with: chunk) == "\nb\nc\nd\n\n")
        #expect(MarkdownSyntaxStyler.chunk(around: NSRange(location: 0, length: 0), in: text) == NSRange(location: 0, length: 3))
        #expect(MarkdownSyntaxStyler.chunk(around: NSRange(location: 0, length: 0), in: "") == NSRange(location: 0, length: 0))
    }

    // MARK: - The ceiling

    /// A document of about `bytes` with the constructs a long note has.
    static func generated(bytes: Int) -> String {
        var text = "# Generated\n\n"
        var section = 1
        while text.utf8.count < bytes {
            text += "## Section \(section)\n\nProse with **bold**, *italic*, `code`, a [link](https://example.com/\(section)), and a -> arrow, long enough to wrap onto a second line in the measure.\n\n"
            text += "- item one with **bold**\n  wrapped continuation\n- item two\n- [ ] a task\n\n"
            if section.isMultiple(of: 3) { text += "> a quote with `code`\n> that continues\n\n" }
            if section.isMultiple(of: 4) { text += "```swift\nlet x = 1  // not *italic*\n```\n\n" }
            if section.isMultiple(of: 6) { text += "![missing](images/none.png)\n\n" }
            text += "Closing prose for the section, ~~struck~~ and <u>underlined</u>.\n\n"
            section += 1
        }
        return text
    }

    private func millisecondsPerKeystroke(bytes: Int, count: Int) -> [Double] {
        let text = Self.generated(bytes: bytes)
        let textView = makeEditor(text)
        var location = text.utf16.count / 2
        location = (text as NSString).range(of: "Prose", options: [], range: NSRange(location: location, length: text.utf16.count - location)).location + 5
        var samples: [Double] = []
        for _ in 0..<count {
            textView.insertText("x", replacementRange: NSRange(location: location, length: 0))
            let start = ContinuousClock.now
            textView.syntaxStyler.applyEdited(to: textView)
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            location += 1
        }
        return samples
    }

    /// The restyle after a keystroke covers the chunk around it, so its
    /// cost is flat in document size and fits a frame with room to spare
    /// even in Debug. A regression to the full pass (about 190 ms at
    /// 100 KB in Debug) fails this by an order of magnitude. The text
    /// view's own edit, which relays out from the caret to the end under
    /// contiguous layout, is timed by the probe, not here.
    @Test func aRestyleStaysUnderTheCeilingAtAnySize() {
        let small = millisecondsPerKeystroke(bytes: 10_000, count: 10)
        let large = millisecondsPerKeystroke(bytes: 100_000, count: 10)
        #expect(small.max()! < 16, "10 KB: \(small)")
        #expect(large.max()! < 16, "100 KB: \(large)")
    }
}
