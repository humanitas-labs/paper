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
