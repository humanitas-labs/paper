import AppKit
import Testing
@testable import Paper

/// The outline's headings: the ones the styler draws as headings, with
/// clean titles and ranges into the source.
struct OutlineTests {
    private func titles(_ source: String) -> [String] {
        Outline.headings(in: source).map(\.title)
    }

    @Test
    func extractsLevelsTitlesAndRanges() {
        let source = "# One\n\nbody\n\n## Two\n### Three\n#### Four\n##### Five\n###### Six\n"
        let headings = Outline.headings(in: source)
        #expect(headings.map(\.level) == [1, 2, 3, 4, 5, 6])
        #expect(headings.map(\.title) == ["One", "Two", "Three", "Four", "Five", "Six"])
        let text = source as NSString
        for heading in headings {
            #expect(text.substring(with: heading.contentRange) == heading.title)
            let line = text.substring(with: heading.range)
            #expect(line.hasPrefix(String(repeating: "#", count: heading.level) + " "))
            #expect(!line.contains("\n"))
        }
        #expect(headings[1].range == text.range(of: "## Two"))
        #expect(headings[1].contentRange == text.range(of: "Two"))
    }

    @Test
    func followsTheStylersHeadingRule() {
        #expect(titles("#tag\n").isEmpty)
        #expect(titles("####### seven\n").isEmpty)
        #expect(titles("  # indented\n").isEmpty)
        #expect(titles("> # quoted\n").isEmpty)
        #expect(titles("Title\n=====\n\nOther\n-----\n").isEmpty)
        #expect(titles("#\tTab\n") == ["Tab"])
    }

    @Test
    func excludesHeadingsInFencedCode() {
        let source = """
        # Before

        ```sh
        # a shell comment
        ```

        ~~~
        ## tilde
        ~~~

        ````md
        ```
        # nested
        ```
        ````

        ```math
        # not math either
        ```

        ## After
        """
        #expect(titles(source) == ["Before", "After"])
        // An unterminated fence is never a block, so what follows it lists.
        #expect(titles("```\n# open fence\n\n## Still a heading\n") == ["open fence", "Still a heading"])
    }

    @Test
    func excludesHeadingsInComments() {
        #expect(titles("# Kept\n<!--\n# hidden\n-->\n## Also kept\n") == ["Kept", "Also kept"])
        #expect(titles("# Kept\n<!-- never closed\n# gone\n## gone too\n") == ["Kept"])
    }

    @Test(arguments: [
        ("**bold** words", "bold words"),
        ("an *italic* word", "an italic word"),
        ("an _italic_ word", "an italic word"),
        ("__strong__ start", "strong start"),
        ("***both*** ways", "both ways"),
        ("the `code` span", "the code span"),
        ("`` a`b `` tick", "a`b tick"),
        ("`**not bold**` inside", "**not bold** inside"),
        ("a [link](https://example.com) here", "a link here"),
        ("an ![alt](x.png) image", "an alt image"),
        ("a [reference][1] link", "a reference link"),
        ("see <https://a.b/c>", "see https://a.b/c"),
        ("~~gone~~ struck", "gone struck"),
        ("<u>under</u>lined", "underlined"),
        ("<span>tagged</span>", "tagged"),
        (#"\*literal\* stars"#, "*literal* stars"),
        ("Closed ##", "Closed"),
        ("C# stays", "C# stays"),
        ("snake_case_name", "snake_case_name"),
        ("2 * 3 * 4", "2 * 3 * 4"),
        ("math $x^2$ kept", "math $x^2$ kept"),
        ("  spaced   out  ", "spaced out"),
    ])
    func stripsInlineMarkup(content: String, expected: String) {
        #expect(Outline.title(fromContent: content) == expected)
    }

    @Test
    func markupOnlyAndEmptyHeadings() {
        #expect(titles("# **\n") == ["**"])
        #expect(titles("#   \n").isEmpty)
        #expect(titles("## ##\n").isEmpty)
    }

    @Test
    func duplicateTitlesStayDistinct() {
        let headings = Outline.headings(in: "## Notes\n\ntext\n\n## Notes\n")
        #expect(headings.count == 2)
        #expect(headings[0].title == headings[1].title)
        #expect(headings[0].id != headings[1].id)
    }

    @Test
    func rangesAreUTF16() {
        let source = "😀 intro ✨\n\n# 日本語 👋🏽 e\u{301}\n\n## Second 🎉\n"
        let text = source as NSString
        let headings = Outline.headings(in: source)
        #expect(headings.map(\.title) == ["日本語 👋🏽 e\u{301}", "Second 🎉"])
        for heading in headings {
            #expect(text.substring(with: heading.contentRange) == heading.title)
        }
        #expect(headings[1].range.location == text.range(of: "## Second").location)
    }

    @Test
    func crlfLineEndings() {
        let source = "# One\r\n\r\nbody\r\n## Two\r\n"
        let headings = Outline.headings(in: source)
        #expect(headings.map(\.title) == ["One", "Two"])
        let text = source as NSString
        for heading in headings {
            #expect(!text.substring(with: heading.range).contains("\r"))
        }
    }

    @Test
    func sectionIndexFindsTheEnclosingHeading() {
        let source = "intro\n\n# A\n\ntext\n\n## B\n\nmore\n"
        let headings = Outline.headings(in: source)
        let text = source as NSString
        #expect(Outline.sectionIndex(containing: 0, in: headings) == nil)
        #expect(Outline.sectionIndex(containing: headings[0].range.location, in: headings) == 0)
        #expect(Outline.sectionIndex(containing: text.range(of: "text").location, in: headings) == 0)
        #expect(Outline.sectionIndex(containing: headings[1].range.location, in: headings) == 1)
        #expect(Outline.sectionIndex(containing: text.length, in: headings) == 1)
        #expect(Outline.sectionIndex(containing: 5, in: []) == nil)
    }

    /// The outline lists exactly the lines the styler sets in a heading
    /// font, so the two cannot drift apart.
    @Test @MainActor
    func agreesWithTheStyler() {
        let source = """
        # Title

        Some **prose** and `# not a heading`.

        ## Section *one*

        ```
        # inside a fence
        ```

        <!-- # inside a comment -->

        #hashtag and ####### seven

        ### Deep [link](x.md)

        ###### Smallest
        """
        let textView = PaperTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        textView.string = source
        textView.syntaxStyler.apply(to: textView)
        let storage = textView.textStorage!
        var styled: [Int] = []
        let text = source as NSString
        var location = 0
        while location < text.length {
            let line = text.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(line)
            // A styled heading: its marker conceals and its first visible
            // character is in the heading font for its level.
            var level = 0
            while line.location + level < NSMaxRange(line), text.character(at: line.location + level) == 0x23 { level += 1 }
            guard (1...6).contains(level),
                  storage.attribute(.concealable, at: line.location, effectiveRange: nil) != nil else { continue }
            var index = line.location + level
            while index < NSMaxRange(line), [0x20, 0x09].contains(text.character(at: index)) { index += 1 }
            guard index < NSMaxRange(line),
                  let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont,
                  font == Appearance.headingFont(size: Appearance.headingSize(level: level)) else { continue }
            styled.append(line.location)
        }
        #expect(Outline.headings(in: source).map(\.range.location) == styled)
        #expect(styled.count == 4)
    }
}
