import AppKit
import SwiftUI
import Testing
@testable import Paper

/// Offscreen renders of the outline beside the page, for review. Like the
/// other probes they run only when `PAPER_PROBE_DIR` is set. The editor
/// draws through `cacheDisplay`; the SwiftUI column draws through
/// `ImageRenderer` at the window's size and is laid over it, where
/// `DocumentView`'s overlay puts it. There is no window, so there is no
/// title band above the page: everything sits that much higher than in
/// the app, the column with the text.
@MainActor
struct OutlineProbeTests {
    private static let sample: String = {
        var text = """
        # Field notes on a long document

        Paper keeps nothing on the page but the text. The outline sits beside it, quiet, for finding your way around something long.

        """
        let sections: [(Int, String)] = [
            (2, "Why an outline"),
            (3, "What counts as a heading"),
            (3, "Headings with **bold** and `code` in them"),
            (2, "Moving around"),
            (3, "A very long heading that goes on well past the width of the column so that it has to truncate"),
            (2, "Code is not an outline"),
            (2, "Themes and dark mode"),
            (3, "Following the system"),
            (4, "Custom colors"),
            (2, "What stays the same"),
            (2, "Last words"),
        ]
        for (index, (level, title)) in sections.enumerated() {
            text += "\n" + String(repeating: "#", count: level) + " " + title + "\n\n"
            text += "A paragraph of ordinary prose, long enough to wrap across the measure, so each section has some height and the page has somewhere to scroll to. It says nothing much, as sample text should.\n\n"
            if index == 5 {
                text += "```sh\n# a shell comment, not a heading\necho hello\n```\n\n"
            }
            text += "Another paragraph follows, a little shorter than the first.\n"
        }
        return text
    }()

    private func render(
        width: CGFloat,
        height: CGFloat,
        appearance: NSAppearance.Name,
        scrollTo section: Int?,
        name: String
    ) throws -> OutlineModel {
        let dir = try #require(RenderProbeTests.probeDirectory)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let textView = PaperTextView()
        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Appearance.canvas
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.appearance = NSAppearance(named: appearance)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        textView.string = Self.sample
        textView.syntaxStyler.apply(to: textView)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.sizeToFit()

        let model = OutlineModel()
        model.attach(textView: textView, scrollView: scrollView)
        model.setActive(true)
        if let section { model.jump(to: model.headings[section]) }
        // The caret on the heading reveals its marker; park it at the end
        // so the page reads as it does mid-scroll.
        textView.setSelectedRange(NSRange(location: (Self.sample as NSString).length, length: 0))
        scrollView.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = NSSize(width: width, height: height)
        scrollView.cacheDisplay(in: scrollView.bounds, to: rep)

        var column: CGImage?
        try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content:
                OutlineColumn(model: model, scrolls: false)
                    .frame(width: width, height: height, alignment: .topTrailing)
                    .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            )
            renderer.scale = scale
            column = renderer.cgImage
        }
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        if let column {
            // The rep's context is already scaled to points.
            context.cgContext.draw(column, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("\(name).png"))
        return model
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func renderOutline(appearance: NSAppearance.Name) throws {
        guard RenderProbeTests.probeDirectory != nil else { return }
        let model = try render(
            width: 1400, height: 876, appearance: appearance, scrollTo: 4,
            name: "outline-\(appearance == .aqua ? "light" : "dark")"
        )
        #expect(model.current == 4)
        #expect(OutlineColumn.width(forRoom: model.room) == OutlineColumn.maximumWidth)
        #expect(!model.headings.contains { $0.title.contains("shell comment") })
    }

    /// Too little room beside the text: no column, the page unchanged.
    @Test
    func renderOutlineNarrow() throws {
        guard RenderProbeTests.probeDirectory != nil else { return }
        let model = try render(width: 1000, height: 700, appearance: .aqua, scrollTo: nil, name: "outline-narrow")
        #expect(OutlineColumn.width(forRoom: model.room) == nil)
    }

    /// The scan's cost on a megabyte, in this (Debug) build, for the record.
    @Test
    func outlineScanTiming() throws {
        guard let dir = RenderProbeTests.probeDirectory else { return }
        var text = ""
        var index = 0
        while text.utf16.count < 1_000_000 {
            index += 1
            text += "## Section \(index) with **bold** and `code`\n\nA paragraph of ordinary prose that runs for a while, with a [link](https://example.com) and some *emphasis* in it.\n\n- item one\n- item two\n\n"
            if index % 10 == 0 { text += "```swift\n# not a heading\nlet x = 1\n```\n\n" }
        }
        var times: [Double] = []
        var count = 0
        for _ in 0..<3 {
            let start = ContinuousClock.now
            count = Outline.headings(in: text).count
            let elapsed = ContinuousClock.now - start
            times.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        let line = "outline scan, \(text.utf16.count) UTF-16 units, \(count) headings, Debug build: "
            + times.map { String(format: "%.1f ms", $0) }.joined(separator: ", ") + "\n"
        try line.write(to: dir.appendingPathComponent("outline-timing.txt"), atomically: true, encoding: .utf8)
    }
}
