import AppKit
import Testing
@testable import Paper

@MainActor
struct MarkdownSyntaxStylerTests {
    nonisolated static let sources: [String] = [
        "",
        "# Heading\n\nParagraph with **strong**, *emphasis*, and `code`.\n\n- item\n1. item\n",
        "unmatched **strong and *emphasis and `code\n",
        "***nested*** **adjacent****markers** *a**b**c*\n",
        "# 日本語 — 👩‍👩‍👧‍👦 — e\u{301} **café** `naïve`\n",
        "\u{FEFF}## BOM heading\n",
        "> quoted *line*\n>\n> > nested\n>no space\n",
    ]

    @Test(arguments: sources)
    func stylingLeavesSourceUnchanged(source: String) {
        let textView = PaperTextView()
        textView.string = source

        textView.syntaxStyler.apply(to: textView)

        #expect(textView.string == source)
        #expect(textView.textStorage?.string == source)
    }

    @Test
    func stylingPreservesSelection() {
        let textView = PaperTextView()
        textView.string = "Some **strong** text\n"
        let selection = NSRange(location: 7, length: 6)
        textView.setSelectedRange(selection)

        textView.syntaxStyler.apply(to: textView)

        #expect(textView.selectedRange() == selection)
    }

    @Test
    func stylingResetsTypingAttributesToBody() {
        let textView = PaperTextView()
        textView.string = "# Heading\n"
        textView.setSelectedRange(NSRange(location: 9, length: 0))

        textView.syntaxStyler.apply(to: textView)

        let font = textView.typingAttributes[.font] as? NSFont
        #expect(font?.pointSize == Appearance.bodySize)
    }

    @Test
    func stylingDifferentiatesConstructs() {
        let textView = PaperTextView()
        textView.string = "# Heading\n**strong** *em* `code`\n"
        textView.syntaxStyler.apply(to: textView)
        let storage = try! #require(textView.textStorage)

        let headingFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        let markerColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let strongFont = storage.attribute(.font, at: 12, effectiveRange: nil) as? NSFont
        let emFont = storage.attribute(.font, at: 22, effectiveRange: nil) as? NSFont
        let codeFont = storage.attribute(.font, at: 27, effectiveRange: nil) as? NSFont

        #expect(headingFont?.pointSize == Appearance.headingSize(level: 1))
        #expect(markerColor == Appearance.mutedInk)
        #expect(strongFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(emFont?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        #expect(codeFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    @Test
    func commentsRecedeAndStayLiteral() {
        let textView = PaperTextView()
        textView.string = "before <!-- **note** [x](y) --> after\n\n```\n<!-- code -->\n```\n\n# Head <!-- open\n---\n"
        textView.syntaxStyler.apply(to: textView)
        let storage = try! #require(textView.textStorage)
        let text = textView.string as NSString
        func at(_ needle: String) -> Int { text.range(of: needle).location }

        let opener = at("<!--")
        #expect(storage.attribute(.foregroundColor, at: opener, effectiveRange: nil) as? NSColor == Appearance.mutedInk)
        #expect(storage.attribute(.concealable, at: opener, effectiveRange: nil) == nil, "the delimiter stays in view")
        let note = at("note")
        #expect(storage.attribute(.foregroundColor, at: note, effectiveRange: nil) as? NSColor == Appearance.mutedInk)
        #expect((storage.attribute(.font, at: note, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == false, "no Markdown inside a comment")
        #expect(storage.attribute(.linkDestination, at: at("x](y"), effectiveRange: nil) == nil)
        #expect(storage.attribute(.foregroundColor, at: at("after"), effectiveRange: nil) as? NSColor == Appearance.ink, "prose resumes after -->")
        #expect(storage.attribute(.font, at: at("code -->"), effectiveRange: nil) as? NSFont == Appearance.codeFont(), "a comment inside a fence is code")
        let head = at("Head")
        #expect((storage.attribute(.font, at: head, effectiveRange: nil) as? NSFont)?.pointSize == Appearance.headingSize(level: 1), "the heading before the comment keeps its size")
        #expect(storage.attribute(.foregroundColor, at: at("open"), effectiveRange: nil) as? NSColor == Appearance.mutedInk)
        #expect(storage.attribute(.thematicBreak, at: at("---"), effectiveRange: nil) == nil, "an unterminated comment runs to the end")
        #expect(storage.attribute(.foregroundColor, at: at("---"), effectiveRange: nil) as? NSColor == Appearance.mutedInk)
    }
}

extension MarkdownSyntaxStylerTests {
    @Test
    func stylingMarksBlockQuotes() {
        let textView = PaperTextView()
        textView.string = "> quoted text\n>\nplain\n"
        textView.syntaxStyler.apply(to: textView)
        let storage = try! #require(textView.textStorage)

        let markerColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let quoteFont = storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        let quoteStyle = storage.attribute(.paragraphStyle, at: 3, effectiveRange: nil) as? NSParagraphStyle
        let plainFont = storage.attribute(.font, at: 17, effectiveRange: nil) as? NSFont
        let plainStyle = storage.attribute(.paragraphStyle, at: 17, effectiveRange: nil) as? NSParagraphStyle

        #expect(markerColor == Appearance.mutedInk)
        #expect(quoteFont?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        #expect(storage.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor == Appearance.quoteInk)
        #expect(quoteStyle?.firstLineHeadIndent == Appearance.quoteIndent, "quote text is inset from the margin")
        #expect(quoteStyle?.headIndent == Appearance.quoteIndent)
        #expect(quoteStyle?.paragraphSpacing == 0, "followed by another quote line")
        #expect((storage.attribute(.paragraphStyle, at: 14, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing == Appearance.paragraphSpacing, "last quote line keeps the spacing")
        #expect(storage.attribute(.concealable, at: 0, effectiveRange: nil) != nil)
        #expect(plainFont?.fontDescriptor.symbolicTraits.contains(.italic) == false)
        #expect(plainStyle?.headIndent == 0)

        var runRange = NSRange()
        let marked = storage.attribute(
            .blockQuote, at: 0, longestEffectiveRange: &runRange, in: NSRange(location: 0, length: storage.length)
        )
        #expect(marked != nil)
        #expect(runRange == NSRange(location: 0, length: 16), "both quote lines and their newlines form one run")
        #expect(storage.attribute(.blockQuote, at: 17, effectiveRange: nil) == nil)
    }

    @Test
    func inlineTraitsCompose() {
        let textView = PaperTextView()
        textView.string = "> **bold in quote** and ***both***\n"
        textView.syntaxStyler.apply(to: textView)
        let storage = try! #require(textView.textStorage)

        let quoteBold = (storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits
        let both = (storage.attribute(.font, at: 27, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits

        #expect(quoteBold?.contains(.bold) == true)
        #expect(quoteBold?.contains(.italic) == true)
        #expect(both?.contains(.bold) == true)
        #expect(both?.contains(.italic) == true)
    }

    @Test
    func underscoreEmphasisFollowsWordBoundaries() {
        let textView = PaperTextView()
        textView.string = "_word_ __word__ ___word___ ***word*** _two words_ snake_case_name a_b trailing_ _leading *a*_b_ `_x_` <!-- __y__ -->\n"
        textView.syntaxStyler.apply(to: textView)
        let storage = try! #require(textView.textStorage)
        let text = textView.string as NSString
        func at(_ needle: String) -> Int { text.range(of: needle).location }
        func traits(_ index: Int) -> NSFontDescriptor.SymbolicTraits? {
            (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits
        }
        func concealed(_ index: Int) -> Bool { storage.attribute(.concealable, at: index, effectiveRange: nil) != nil }

        #expect(traits(1)?.contains(.italic) == true, "_word_")
        #expect(concealed(0) && concealed(5))
        let strong = at("__word__")
        #expect(traits(strong + 2)?.contains(.bold) == true, "__word__")
        #expect(traits(strong + 2)?.contains(.italic) == false)
        #expect(concealed(strong) && concealed(strong + 1) && concealed(strong + 6) && concealed(strong + 7))
        for triple in ["___word___", "***word***"] {
            let start = at(triple)
            #expect(traits(start + 3)?.contains(.bold) == true, "\(triple) is bold")
            #expect(traits(start + 3)?.contains(.italic) == true, "\(triple) is italic")
            for offset in [0, 1, 2, 7, 8, 9] { #expect(concealed(start + offset), "\(triple) delimiter \(offset)") }
        }
        let two = at("_two words_")
        #expect(traits(two + 5)?.contains(.italic) == true, "spaces inside the pair")
        #expect(concealed(two) && concealed(two + 10))

        for literal in ["snake_case_name", "a_b", "_leading", "trailing_"] {
            let range = text.range(of: literal)
            for index in range.location..<NSMaxRange(range) {
                #expect(traits(index)?.contains(.italic) == false, "\(literal) is literal")
                #expect(traits(index)?.contains(.bold) == false, "\(literal) is literal")
                #expect(!concealed(index), "\(literal) stays visible")
            }
        }
        let mixed = at("*a*_b_")
        #expect(traits(mixed + 1)?.contains(.italic) == true)
        #expect(traits(mixed + 4)?.contains(.italic) == true, "an underscore pair after a star pair")
        #expect(concealed(mixed + 3) && concealed(mixed + 5))
        let code = at("_x_")
        #expect(traits(code + 1)?.contains(.italic) == false, "a code span stays literal")
        #expect(!concealed(code))
        let comment = at("__y__")
        #expect(traits(comment + 2)?.contains(.bold) == false, "no Markdown inside a comment")
        #expect(!concealed(comment))
    }

    @Test
    func asteriskDelimitersNeedVisibleContentAgainstThem() {
        let textView = PaperTextView()
        textView.string = "* *Label:* text\n2 * 3 * 4 and ** a ** and *** b ***\n"
        textView.syntaxStyler.apply(to: textView)
        let storage = try! #require(textView.textStorage)
        let text = textView.string as NSString
        func at(_ needle: String) -> Int { text.range(of: needle).location }
        func traits(_ index: Int) -> NSFontDescriptor.SymbolicTraits? {
            (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits
        }
        func concealed(_ index: Int) -> Bool { storage.attribute(.concealable, at: index, effectiveRange: nil) != nil }

        let label = at("*Label:*")
        #expect(traits(label + 1)?.contains(.italic) == true, "the label after a star bullet is italic")
        #expect(concealed(label) && concealed(label + 7))
        #expect(storage.attribute(.listMarker, at: 0, effectiveRange: nil) != nil, "the star stays a bullet")
        #expect(!concealed(0) && !concealed(1), "the bullet is not taken as an emphasis delimiter")
        #expect(traits(at(" text"))?.contains(.italic) == false)

        for literal in ["2 * 3 * 4", "** a **", "*** b ***"] {
            let range = text.range(of: literal)
            for index in range.location..<NSMaxRange(range) {
                #expect(traits(index)?.contains(.italic) == false, "\(literal) is literal")
                #expect(traits(index)?.contains(.bold) == false, "\(literal) is literal")
            }
        }
    }

    @Test
    func strikethroughComposesAndStaysOutOfCodeAndComments() {
        let textView = PaperTextView()
        textView.string = "**~~both~~** `~~code~~` <!-- ~~note~~ --> ~single~ a~~b\n"
        textView.syntaxStyler.apply(to: textView)
        let storage = try! #require(textView.textStorage)
        let text = textView.string as NSString
        func at(_ needle: String) -> Int { text.range(of: needle).location }

        let both = at("both")
        #expect(storage.attribute(.strikethroughStyle, at: both, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        #expect((storage.attribute(.font, at: both, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let code = at("code")
        #expect(storage.attribute(.strikethroughStyle, at: code, effectiveRange: nil) == nil, "a code span stays literal")
        #expect(storage.attribute(.concealable, at: code - 2, effectiveRange: nil) == nil)
        #expect(storage.attribute(.font, at: code - 2, effectiveRange: nil) as? NSFont == Appearance.codeFont())
        let note = at("note")
        #expect(storage.attribute(.strikethroughStyle, at: note, effectiveRange: nil) == nil, "no Markdown inside a comment")
        #expect(storage.attribute(.concealable, at: note - 2, effectiveRange: nil) == nil)
        #expect(storage.attribute(.strikethroughStyle, at: at("single"), effectiveRange: nil) == nil, "a lone tilde is prose")
        #expect(storage.attribute(.concealable, at: at("a~~b") + 1, effectiveRange: nil) == nil, "an unpaired ~~ is prose")
    }
}

struct SelectionClampingTests {
    @Test
    func clampsLocationAndLengthIntoText() {
        #expect(NSRange(location: 3, length: 4).clamped(to: 10) == NSRange(location: 3, length: 4))
        #expect(NSRange(location: 8, length: 4).clamped(to: 10) == NSRange(location: 8, length: 2))
        #expect(NSRange(location: 12, length: 4).clamped(to: 10) == NSRange(location: 10, length: 0))
        #expect(NSRange(location: 0, length: 0).clamped(to: 0) == NSRange(location: 0, length: 0))
    }
}

@MainActor
struct ConfigurationDrivenAppearanceTests {
    private func withConfiguration<T>(_ configuration: Configuration, _ body: () throws -> T) rethrows -> T {
        let store = ConfigurationStore.shared
        let saved = store.current
        defer { store.apply(saved) }
        store.apply(configuration)
        return try body()
    }

    /// Six heading levels are six sizes, each smaller than the last, with
    /// `######` at the body size, told apart by weight alone (#38).
    @Test
    func sixHeadingLevelsAreSixSizes() throws {
        let sizes = (1...6).map { Appearance.headingSize(level: $0) }
        #expect(sizes == sizes.sorted(by: >))
        #expect(Set(sizes).count == 6)
        #expect(sizes[5] == Appearance.bodySize)
        #expect(sizes[0] == Appearance.bodySize + 12)

        let textView = PaperTextView()
        textView.string = "##### Five\n\n###### Six\n"
        textView.syntaxStyler.apply(to: textView)
        let storage = try #require(textView.textStorage)
        let text = textView.string as NSString
        let five = text.range(of: "Five").location
        let six = text.range(of: "Six").location
        #expect((storage.attribute(.font, at: five, effectiveRange: nil) as? NSFont)?.pointSize == Appearance.headingSize(level: 5))
        #expect((storage.attribute(.font, at: six, effectiveRange: nil) as? NSFont)?.pointSize == Appearance.bodySize)
        #expect(storage.attribute(.foregroundColor, at: six, effectiveRange: nil) as? NSColor == Appearance.ink, "weight alone marks it")
        #expect(storage.attribute(.font, at: six, effectiveRange: nil) as? NSFont == Appearance.headingFont(size: Appearance.bodySize))
    }

    @Test
    func configurationDrivesBodyFontAndHeadings() {
        var config = Configuration()
        config.fontFamily = "Georgia"
        config.fontSize = 20
        config.lineHeight = 1.5
        config.paragraphSpacing = 20
        config.measure = 700
        config.headingWeight = 700
        config.letterSpacing = 0.5
        withConfiguration(config) {
            #expect(Appearance.letterSpacing == 0.5)
            #expect(MarkdownSyntaxStyler.baseAttributes[.kern] as? CGFloat == 0.5)
            #expect(Appearance.bodySize == 20)
            #expect(Appearance.bodyFont().familyName == "Georgia")
            #expect(Appearance.headingSize(level: 1) == 32)
            #expect(Appearance.headingSize(level: 2) == 28)
            #expect(Appearance.headingSize(level: 6) == 20)
            #expect(Appearance.paragraphStyle().lineHeightMultiple == 1.5)
            #expect(Appearance.paragraphStyle().paragraphSpacing == 20)
            #expect(Appearance.maximumMeasure == 700)
            #expect(Appearance.headingFont(size: 30).fontDescriptor.symbolicTraits.contains(.bold))
        }

        config.fontFamily = "No Such Family"
        withConfiguration(config) {
            #expect(Appearance.bodyFont().familyName != "No Such Family")
        }
    }

    /// `color` resolved under an appearance, in sRGB.
    private func resolve(_ color: NSColor, appearance: NSAppearance.Name) -> NSColor {
        var resolved = color
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    @Test
    func explicitTonesReplaceTheInkDerivationPerAppearance() {
        var config = Configuration()
        config.colorOverrides.inkMuted = "#FF0000"
        withConfiguration(config) {
            let light = resolve(Appearance.mutedInk, appearance: .aqua)
            #expect(light.redComponent == 1 && light.greenComponent == 0 && light.alphaComponent == 1)
            let dark = resolve(Appearance.mutedInk, appearance: .darkAqua)
            #expect(dark.alphaComponent < 0.5, "the dark form still derives from the ink")
            let quote = resolve(Appearance.quoteInk, appearance: .aqua)
            #expect(quote.alphaComponent < 1, "other tones still derive")
        }
        withConfiguration(Configuration()) {
            #expect(resolve(Appearance.mutedInk, appearance: .aqua).alphaComponent < 1)
        }
    }

}
