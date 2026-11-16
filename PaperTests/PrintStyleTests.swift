import AppKit
import PDFKit
import Testing
@testable import Paper

/// Export styles: the page keys, the built-ins, style files beside the
/// config, and the book page on a print surface and in a PDF.
@MainActor
struct PrintStyleTests {
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("paper-print-style-\(UUID().uuidString)", isDirectory: true)

    @Test
    func pageKeysAreReadAndBadValuesSkipped() {
        let page = PrintStyle.Page.parse("""
        # a comment
        text.align = Justified
        hyphenation = on
        paragraph.indent = 2
        heading.align = centre
        heading.case = upper
        heading.tracking = 5
        page.numbers = yes
        font.family = Charter
        """)
        #expect(page.alignment == .justified)
        #expect(page.hyphenation)
        #expect(page.paragraphIndent == 2)
        #expect(page.headingAlignment == .center)
        #expect(page.headingCase == .upper)
        #expect(page.headingTracking == 1, "clamped to the range")
        #expect(page.pageNumbers)

        let bad = PrintStyle.Page.parse("text.align = middle\nhyphenation = maybe\nparagraph.indent = lots")
        #expect(bad == PrintStyle.Page())
        #expect(PrintStyle.paper.page.isEditorPage)
        #expect(!PrintStyle.book.page.isEditorPage)
    }

    @Test
    func pageSizeTakesNamesAndMeasures() {
        typealias Page = PrintStyle.Page
        #expect(Page.parse("page.size = trade").pageSize == NSSize(width: 432, height: 648))
        #expect(Page.parse("page.size = 5 x 8").pageSize == NSSize(width: 360, height: 576))
        #expect(Page.parse("page.size = 5.5x8.5 in").pageSize == NSSize(width: 396, height: 612))
        let mm = Page.parse("page.size = 148 x 210 mm").pageSize
        #expect(abs((mm?.width ?? 0) - 419.53) < 0.01)
        #expect(Page.parse("page.size = 1 x 100").pageSize == NSSize(width: 144, height: 1440), "sides clamp to 2–20 in")
        #expect(Page.parse("page.size = huge").pageSize == nil)
        #expect(Page.parse("page.size = trade").isEditorPage, "the sheet alone leaves the styler's page")
    }

    @Test
    func aStyleSizesTheSheet() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("small.pdf")
        let style = PrintStyle(name: "small", text: "page.size = 5 x 8\nprint.margin = 40")
        try PDFExporter.export(text: "# Small\n\nA page the size of a book's.", documentURL: nil, to: output, paper: .letter, style: style)
        let box = try #require(PDFDocument(url: output)?.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(box.width - 360) < 0.5 && abs(box.height - 576) < 0.5)
    }

    /// A margin narrower than the view's own inset once put a zero sheet
    /// margin on the left, which the print system moved out to the
    /// printer's edge, and the column sat right of center.
    @Test
    func aNarrowMarginStaysCentered() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("narrow.pdf")
        let style = PrintStyle(name: "narrow", text: "page.size = 5 x 8\nprint.margin = 40\ntext.align = justified")
        let words = String(repeating: "Words that run on and on across the measure so every line is full. ", count: 30)
        try PDFExporter.export(text: words, documentURL: nil, to: output, paper: .letter, style: style)
        let page = try #require(PDFDocument(url: output)?.page(at: 0))
        let ink = try #require(Self.inkColumns(of: page))
        let width = page.bounds(for: .mediaBox).width
        #expect(abs(ink.left - (width - ink.right)) < 2, "left \(ink.left), right \(width - ink.right)")
        #expect(ink.left < 48, "the margin as set, not widened to the view's inset")
    }

    /// The leftmost and rightmost inked columns of a page, in points.
    private static func inkColumns(of page: PDFPage) -> (left: CGFloat, right: CGFloat)? {
        let size = page.bounds(for: .mediaBox).size
        let scale: CGFloat = 2
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var minX = w, maxX = -1
        for y in 0..<h { for x in 0..<w where pixels[y * w + x] < 128 { minX = min(minX, x); maxX = max(maxX, x) } }
        return maxX < 0 ? nil : (CGFloat(minX) / scale, CGFloat(maxX + 1) / scale)
    }

    @Test
    func aStyleLaysItsConfigKeysOverTheConfig() {
        var base = Configuration()
        base.fontSize = 18
        base.printMargin = 40
        let style = PrintStyle(name: " Memo ", text: "font.family = Charter\nprint.margin = 72\ntext.align = justified")
        let configuration = style.configuration(over: base)
        #expect(style.name == "memo")
        #expect(configuration.fontFamily == "Charter")
        #expect(configuration.printMargin == 72)
        #expect(configuration.fontSize == 18, "keys the style leaves alone keep the config's value")
        #expect(PrintStyle.paper.configuration(over: base) == base)
    }

    @Test
    func printStyleIsAConfigKey() {
        #expect(Configuration().printStyle == "paper")
        #expect(Configuration.parse("print.style = book").printStyle == "book")
        #expect(Configuration.parse("print.style =").printStyle == "paper")
        #expect(Configuration.template.contains("print.style = paper"))
        #expect(Configuration.parse("print.style = book").entries.contains { $0.key == "print.style" && $0.value == "book" })
    }

    @Test
    func styleFilesSitBesideTheConfigAndReplaceBuiltIns() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let configURL = folder.appendingPathComponent("config")
        let styles = folder.appendingPathComponent("styles", isDirectory: true)
        try FileManager.default.createDirectory(at: styles, withIntermediateDirectories: true)
        try "print.style = Memo".write(to: configURL, atomically: true, encoding: .utf8)
        try "page.numbers = on".write(to: styles.appendingPathComponent("memo"), atomically: true, encoding: .utf8)
        try "text.align = justified".write(to: styles.appendingPathComponent("book"), atomically: true, encoding: .utf8)
        try "ignored".write(to: styles.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

        let store = ConfigurationStore(fileURL: configURL)
        defer { ConfigurationStore.forgetActivePreset(for: configURL) }
        store.reload()
        #expect(store.printStyles().map(\.name) == ["paper", "book", "memo"])
        #expect(store.printStyle(named: "BOOK")?.page.pageNumbers == false, "the file replaced the built-in book")
        #expect(store.printStyle(named: "nope") == nil)
        #expect(store.defaultPrintStyle.name == "memo")

        try "print.style = gone".write(to: configURL, atomically: true, encoding: .utf8)
        store.reload()
        #expect(store.defaultPrintStyle == .paper)
    }

    // MARK: - The book page

    private let sample = """
    # The Title

    First paragraph, which follows the heading and so is not indented.

    Second paragraph, a new one after a blank line.
    A hard-wrapped line continuing it.

    - a list item

    Third paragraph after the list.
    """

    private func bookSurface() -> PaperTextView {
        let textView = PaperTextView()
        textView.isPrintSurface = true
        textView.printPage = PrintStyle.book.page
        textView.frame = NSRect(x: 0, y: 0, width: 700, height: 100)
        textView.string = sample
        textView.syntaxStyler.apply(to: textView)
        return textView
    }

    private func style(ofLine index: Int, in textView: PaperTextView) -> NSParagraphStyle {
        let storage = textView.textStorage!
        let line = PrintStyle.Page.lines(of: storage)[index].range
        return storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as! NSParagraphStyle
    }

    @Test
    func linesAreToldApartFromTheStylersAttributes() {
        let textView = bookSurface()
        let kinds = PrintStyle.Page.lines(of: textView.textStorage!).map(\.kind)
        #expect(kinds == [.heading, .blank, .prose, .blank, .prose, .prose, .blank, .other, .blank, .prose])
    }

    @Test
    func bookParagraphsAreIndentedJustifiedAndCloseUp() {
        let textView = bookSurface()
        let first = style(ofLine: 2, in: textView)
        let second = style(ofLine: 4, in: textView)
        let continuation = style(ofLine: 5, in: textView)
        let afterList = style(ofLine: 9, in: textView)
        #expect(first.firstLineHeadIndent == 0, "the first after a heading takes no indent")
        #expect(first.alignment == .justified && first.hyphenationFactor == 1)
        #expect(first.paragraphSpacing == 0, "a paragraph followed by another takes no space after it")
        #expect(abs(second.firstLineHeadIndent - PrintStyle.book.page.paragraphIndent * Appearance.bodySize) < 0.001)
        #expect(continuation.firstLineHeadIndent == 0, "a hard-wrapped line is not a new paragraph")
        #expect(afterList.firstLineHeadIndent == 0, "the first after a list takes no indent")
        #expect(style(ofLine: 3, in: textView).maximumLineHeight < 0.1, "the blank between two paragraphs closes up")
        #expect(style(ofLine: 6, in: textView).maximumLineHeight == 0, "the blank before the list stays")
        #expect(style(ofLine: 7, in: textView).alignment != .justified, "the list keeps the styler's paragraph")
    }

    @Test
    func bookHeadingsAreCenteredCapitalsWithoutTouchingTheText() {
        let textView = bookSurface()
        let storage = textView.textStorage!
        #expect(style(ofLine: 0, in: textView).alignment == .center)
        let title = (storage.string as NSString).range(of: "The Title")
        #expect(storage.attribute(.glyphSubstitute, at: title.location + 1, effectiveRange: nil) as? String == "H")
        #expect(storage.attribute(.glyphSubstitute, at: title.location, effectiveRange: nil) == nil, "a capital stays itself")
        #expect((storage.attribute(.kern, at: title.location, effectiveRange: nil) as? CGFloat ?? 0) > 0)
        #expect(storage.string == sample)
    }

    @Test
    func theEditorPageIsUntouched() {
        let textView = PaperTextView()
        textView.isPrintSurface = true
        textView.printPage = PrintStyle.paper.page
        textView.frame = NSRect(x: 0, y: 0, width: 700, height: 100)
        textView.string = sample
        textView.syntaxStyler.apply(to: textView)
        let storage = textView.textStorage!
        let line = PrintStyle.Page.lines(of: storage)[4].range
        let style = storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as! NSParagraphStyle
        #expect(style.firstLineHeadIndent == 0 && style.alignment != .justified)
        #expect(storage.attribute(.glyphSubstitute, at: 3, effectiveRange: nil) == nil)
    }

    @Test
    func bookPagesAreNumberedAndPaperPagesAreNot() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let long = (1...30).map { "Paragraph \($0) runs across the measure a few times so the document is several pages long and the breaks land in the middle of things." }
            .joined(separator: "\n\n")
        let book = folder.appendingPathComponent("book.pdf")
        let paper = folder.appendingPathComponent("paper.pdf")
        try PDFExporter.export(text: "# Title\n\n" + long, documentURL: nil, to: book, paper: .letter, style: .book)
        try PDFExporter.export(text: "# Title\n\n" + long, documentURL: nil, to: paper, paper: .letter, style: .paper)
        let bookDocument = try #require(PDFDocument(url: book))
        #expect(bookDocument.pageCount >= 2)
        for index in 0..<bookDocument.pageCount {
            let text = bookDocument.page(at: index)?.string ?? ""
            #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("\(index + 1)"))
        }
        let paperDocument = try #require(PDFDocument(url: paper))
        let lastLine = paperDocument.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).last ?? ""
        #expect(lastLine != "1", "no number on a paper page")
    }
}
