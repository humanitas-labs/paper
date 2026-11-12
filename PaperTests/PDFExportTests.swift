import AppKit
import PDFKit
import Testing
@testable import Paper

@MainActor
struct PDFExportTests {
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("paper-pdf-export-\(UUID().uuidString)")

    private func makeFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func writePNG(_ name: String, width: Int, height: Int) -> URL {
        makeFolder()
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let url = folder.appendingPathComponent(name)
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    private var long: String {
        (1...40).map { "Paragraph \($0) runs across the measure a few times so the document is several pages long and the breaks land in the middle of things." }
            .joined(separator: "\n\n")
    }

    @Test
    func letterAndA4PagesAtTheirSizes() throws {
        makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for paper in PDFExporter.Paper.allCases {
            let output = folder.appendingPathComponent("\(paper.rawValue).pdf")
            try PDFExporter.export(text: "# Title\n\n" + long, documentURL: nil, to: output, paper: paper)
            let document = try #require(PDFDocument(url: output))
            #expect(document.pageCount >= 3)
            let box = try #require(document.page(at: 0)).bounds(for: .mediaBox)
            #expect(abs(box.width - paper.size.width) < 0.5 && abs(box.height - paper.size.height) < 0.5)
        }
    }

    @Test
    func linksAreClickableAndFragmentsAreNot() throws {
        makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let filler = String(repeating: "Words that fill the line so the link below wraps onto a second line. ", count: 4)
        let text = """
        A [remote link](https://example.com/page) and a [local one](notes/other.md) and a [fragment](#heading).

        \(filler)[a link whose text is long enough to wrap around the end of the line and continue](https://example.com/wrapped)

        ## Heading
        """
        let output = folder.appendingPathComponent("links.pdf")
        let document = folder.appendingPathComponent("doc.md")
        try PDFExporter.export(text: text, documentURL: document, to: output)
        let pdf = try #require(PDFDocument(url: output))
        var urls: [String] = []
        for index in 0..<pdf.pageCount {
            for annotation in pdf.page(at: index)?.annotations ?? [] {
                if let url = annotation.url { urls.append(url.absoluteString) }
            }
        }
        #expect(urls.contains("https://example.com/page"))
        #expect(urls.contains(folder.appendingPathComponent("notes/other.md").absoluteString), "a relative destination resolves beside the document")
        #expect(urls.filter { $0 == "https://example.com/wrapped" }.count >= 2, "a wrapped link gets a rectangle per line")
        #expect(!urls.contains { $0.hasSuffix("#heading") }, "a fragment has no anchor in the PDF")
    }

    @Test
    func aTableExportsAsItsGrid() throws {
        makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rows = (1...60).map { "| Row \($0) | A cell with enough words in it to wrap inside its column on the page | **Done** |" }
        let text = "Before.\n\n| Name | Meaning | State |\n| --- | --- | :---: |\n" + rows.joined(separator: "\n") + "\n\nAfter."
        let output = folder.appendingPathComponent("table.pdf")
        try PDFExporter.export(text: text, documentURL: nil, to: output)
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount > 1)
        let extracted = try #require(document.string)
        for word in ["Name", "Meaning", "State", "Row 1", "Row 60", "Done", "After."] {
            #expect(extracted.contains(word), Comment(rawValue: word))
        }
        #expect(!extracted.contains("|"))
        #expect(!extracted.contains("---"))
        #expect(!extracted.contains("**"))
    }

    @Test
    func extractedTextHidesMarkersAndKeepsWords() throws {
        makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = """
        # Heading

        Some **bold** and `code` and a [link](https://example.com).

        ```swift
        let x = 1
        ```

        - [x] done
        """
        let output = folder.appendingPathComponent("markers.pdf")
        try PDFExporter.export(text: text, documentURL: nil, to: output)
        let extracted = try #require(PDFDocument(url: output)?.string)
        #expect(extracted.contains("Heading"))
        #expect(extracted.contains("let x = 1"))
        #expect(extracted.contains("done"))
        #expect(!extracted.contains("# Heading"))
        #expect(!extracted.contains("**"))
        #expect(!extracted.contains("```"))
        #expect(!extracted.contains("](https"))
        #expect(!extracted.contains("[x]"))
    }

    @Test
    func emptyDocumentIsOneBlankPage() throws {
        makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("empty.pdf")
        try PDFExporter.export(text: "", documentURL: nil, to: output)
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 1)
        let extracted = document.string ?? ""
        #expect(!extracted.contains(PaperTextView.placeholderTitle))
    }

    @Test
    func imagesDrawAndAMissingOneShowsItsAltText() throws {
        let image = writePNG("pic.png", width: 400, height: 300)
        defer { try? FileManager.default.removeItem(at: folder) }
        let documentURL = folder.appendingPathComponent("doc.md")
        let output = folder.appendingPathComponent("image.pdf")
        try PDFExporter.export(text: "before\n\n![](pic.png)\n\nafter", documentURL: documentURL, to: output)
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 1)
        #expect(!(document.string ?? "").contains("pic.png"))

        // As on screen: no file, no band, the alt text muted in its place.
        try FileManager.default.removeItem(at: image)
        ImageStore.shared.forget(image.standardizedFileURL)
        try PDFExporter.export(text: "![A picture that left](pic.png)", documentURL: documentURL, to: output)
        let extracted = try #require(PDFDocument(url: output)?.string)
        #expect(extracted.contains("A picture that left"))
    }

    @Test
    func zoomLeavesTheExportAloneAndIsRestored() throws {
        makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let previous = Zoom.scale
        defer { Zoom.set(previous) }
        let text = "# Title\n\n" + long

        Zoom.reset()
        let plain = folder.appendingPathComponent("z100.pdf")
        try PDFExporter.export(text: text, documentURL: nil, to: plain)

        Zoom.set(2)
        let zoomed = folder.appendingPathComponent("z200.pdf")
        try PDFExporter.export(text: text, documentURL: nil, to: zoomed)
        #expect(Zoom.scale == 2)

        let a = try #require(PDFDocument(url: plain))
        let b = try #require(PDFDocument(url: zoomed))
        #expect(a.pageCount == b.pageCount)
        #expect(a.string == b.string)
    }

    /// The text of each page.
    private func pages(of text: String, named name: String) throws -> [String] {
        makeFolder()
        let output = folder.appendingPathComponent(name)
        try PDFExporter.export(text: text, documentURL: nil, to: output, paper: .letter)
        let document = try #require(PDFDocument(url: output))
        return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    @Test
    func aPageBreakCommentStartsTheNextPage() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = "# One\n\nAlpha.\n\n<!-- pagebreak -->\n\n## Two\n\nBravo.\n\n<!--PAGEBREAK-->\n## Three\n\nCharlie."
        let pages = try pages(of: text, named: "breaks.pdf")
        try #require(pages.count == 3)
        #expect(pages[0].contains("Alpha") && !pages[0].contains("Two"))
        #expect(pages[1].contains("Two") && pages[1].contains("Bravo") && !pages[1].contains("Three"))
        #expect(pages[2].contains("Three") && pages[2].contains("Charlie"))
        #expect(!pages.joined().lowercased().contains("pagebreak"), "the marker itself is not printed")
    }

    @Test
    func aPageBreakInALongDocumentKeepsTheBreaksBeforeIt() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = try pages(of: long + "\n\nZulu.", named: "plain.pdf")
        let broken = try pages(of: long + "\n\n<!-- pagebreak -->\n\nZulu.", named: "broken.pdf")
        #expect(plain.count >= 3)
        // Zulu shared the last page; now it has one to itself.
        #expect(broken.count == plain.count + 1)
        #expect(broken.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "Zulu.")
        #expect(Array(broken.dropLast(2)) == Array(plain.dropLast()))
    }

    @Test
    func onlyACommentAloneOnItsLineBreaksThePage() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = [
            "Inline `<!-- pagebreak -->` code and a <!-- pagebreak --> comment in a line.",
            "```\n<!-- pagebreak -->\n```",
            "<!-- pagebreak: not the marker -->",
            "Last.",
            "<!-- pagebreak -->\n",
        ].joined(separator: "\n\n")
        let pages = try pages(of: text, named: "literal.pdf")
        #expect(pages.count == 1, "nothing here breaks, and a marker with nothing after it adds no blank page")
    }

    @Test
    func onScreenAPageBreakIsAnOrdinaryComment() {
        let textView = PaperTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        textView.string = "Alpha.\n\n<!-- pagebreak -->\n\nBravo."
        textView.syntaxStyler.apply(to: textView)
        let storage = textView.textStorage!
        let marker = (storage.string as NSString).range(of: "<!-- pagebreak -->")
        #expect(storage.attribute(.pageBreak, at: marker.location, effectiveRange: nil) != nil)
        #expect(storage.attribute(.concealable, at: marker.location, effectiveRange: nil) == nil, "it stays in view while writing")
    }

    @Test
    func aMissingFolderFailsBeforeThePrintOperation() throws {
        makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A save job that cannot open its file goes to the default printer;
        // the exporter must refuse first.
        #expect(throws: PDFExporter.Failure.self) {
            try PDFExporter.export(text: "# Title", documentURL: nil, to: folder.appendingPathComponent("absent/out.pdf"))
        }
    }

    @Test
    func aFailedWriteLeavesTheDestination() throws {
        makeFolder()
        let output = folder.appendingPathComponent("kept.pdf")
        try Data("keep".utf8).write(to: output)
        // A folder that takes no new file: the staging copy cannot be made.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        #expect(throws: PDFExporter.Failure.self) {
            try PDFExporter.export(text: "# Title", documentURL: nil, to: output)
        }
        #expect(try Data(contentsOf: output) == Data("keep".utf8))
    }
}
