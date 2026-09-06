import AppKit
import PDFKit
import Testing
@testable import Paper

/// The PDF export probe: a document with an image band and a code block
/// each meeting a page break, through `PDFExporter` onto Letter pages.
/// Writes `pdf-probe.pdf` and a PNG per page into `PAPER_PROBE_DIR` when
/// set, a temporary folder otherwise, for review by eye; asserts what can
/// be read back: page count, no leaked markers, the visible words present.
@MainActor
struct PDFExportProbeTests {
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("paper-pdf-probe-\(UUID().uuidString)")

    private func writePNG(_ name: String, width: Int, height: Int) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.white.setFill()
        NSRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        let url = folder.appendingPathComponent(name)
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    private var fixture: String {
        let filler = (1...6).map { n in
            "Paragraph \(n) of the filler runs long enough to wrap across the measure a few times, so the page fills at a steady pace and the break lands where the probe wants it, inside a band or a block rather than between two plain paragraphs."
        }.joined(separator: "\n\n")
        return """
        # Probe Title

        A first paragraph with **bold**, *italic*, `inline code`, ~~struck~~ text, and a [link to Paper](https://github.com/humanitas-labs/paper).

        > A quote that is long enough to wrap onto a second line so the rule spans more than one fragment.

        - [ ] an open task
        - [x] a finished task
        - a plain item
          - a nested item
        1. first ordered
        2. second ordered

        ---

        \(filler)

        ## Straddling Image

        ![A tall picture](tall.png)

        \(filler)

        ## Straddling Code

        ```swift
        \((1...40).map { "let line\($0) = \"code line \($0) sits inside the block\"" }.joined(separator: "\n"))
        ```

        Closing paragraph after the code block, with a final [external link](https://example.com/page) at the end.

        """
    }

    @Test
    func letterPagesThroughTheExporter() throws {
        let previousZoom = Zoom.scale
        Zoom.set(1.5) // the export must not see it
        defer { Zoom.set(previousZoom) }

        _ = writePNG("tall.png", width: 800, height: 620)
        defer { try? FileManager.default.removeItem(at: folder) }
        let documentURL = folder.appendingPathComponent("doc.md")

        let dir = RenderProbeTests.probeDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paper-pdf-probe")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = dir.appendingPathComponent("pdf-probe.pdf")
        try PDFExporter.export(text: fixture, documentURL: documentURL, to: output, paper: .letter)

        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount >= 4)
        let box = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        #expect(box.size == NSSize(width: 612, height: 792))

        let text = document.string ?? ""
        #expect(text.contains("Probe Title"))
        #expect(text.contains("Closing paragraph"))
        #expect(text.contains("code line 40"))
        #expect(!text.contains("# Probe"))
        #expect(!text.contains("```"))
        #expect(!text.contains("**bold**"))
        #expect(!text.contains("tall.png"))
        #expect(!text.contains("](https://"))

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let image = page.thumbnail(of: NSSize(width: 1224, height: 1584), for: .mediaBox)
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("pdf-probe-page\(index + 1).png"))
            }
        }
        let annotations = (0..<document.pageCount).flatMap { document.page(at: $0)?.annotations ?? [] }
        print("PDF probe: \(document.pageCount) pages, \(annotations.count) annotations -> \(output.path)")
    }

    /// A real document: `PAPER_PROBE_DOC` names a Markdown file, exported
    /// beside the other probe output as `pdf-probe-doc.pdf` with a PNG
    /// per page, for review by eye. Skipped otherwise.
    @Test
    func exportsTheDocumentNamedInTheEnvironment() throws {
        guard let path = RenderProbeTests.probeEnvironment("PAPER_PROBE_DOC") else { return }
        let source = URL(fileURLWithPath: path)
        let text = try String(contentsOf: source, encoding: .utf8)
        let dir = RenderProbeTests.probeDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paper-pdf-probe")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = dir.appendingPathComponent("pdf-probe-doc.pdf")
        try PDFExporter.export(text: text, documentURL: source, to: output, paper: .letter)
        let document = try #require(PDFDocument(url: output))
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let image = page.thumbnail(of: NSSize(width: 1224, height: 1584), for: .mediaBox)
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("pdf-probe-doc-page\(index + 1).png"))
            }
        }
        print("PDF doc probe: \(document.pageCount) pages -> \(output.path)")
    }
}
