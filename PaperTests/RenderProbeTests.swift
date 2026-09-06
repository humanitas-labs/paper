import AppKit
import Testing
@testable import Paper

/// Offscreen renders and restyle timings for manual review. Runs only when
/// `PAPER_PROBE_DIR` is set: the scheme takes it from the build setting of
/// the same name, so pass `PAPER_PROBE_DIR=/abs/path` to `xcodebuild test`;
/// otherwise every probe is skipped.
@MainActor
struct RenderProbeTests {
    nonisolated static var probeDirectory: URL? {
        probeEnvironment("PAPER_PROBE_DIR").map { URL(fileURLWithPath: $0) }
    }

    /// The scheme sets every probe variable, empty when not passed.
    nonisolated static func probeEnvironment(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name] ?? ""
        return value.isEmpty ? nil : value
    }

    private func makeEditor(width: CGFloat, height: CGFloat, text: String) -> (NSScrollView, PaperTextView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let textView = PaperTextView()
        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Appearance.canvas
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        textView.string = text
        textView.syntaxStyler.apply(to: textView)
        return (scrollView, textView)
    }

    /// The README screenshot: a demo document through the real pipeline
    /// with the current configuration.
    @Test
    func renderReadmeShot() throws {
        guard let dir = Self.probeDirectory else { return }
        let text = """
        # Paper

        Plain Markdown, set like a page. The file on disk is ordinary text; the markers live in the source and step out of the way while you read.

        > Writing is the process by which you realize that you do not understand what you are talking about.

        What it keeps out of sight until the caret arrives:

        - heading marks, quote marks, and inline `code` ticks
        - **bold**, *italic*, and [links](https://github.com/humanitas-labs/paper)
        - typed substitutions, like -> for an arrow

        1. Ordered lists hang under their text
        2. Dashed and bulleted lists take Apple Notes' two kinds
        3. Everything above is still just Markdown in the file

        Settings live in `~/.config/paper/config`, themed, and applied live.

        """
        let (scrollView, textView) = makeEditor(width: 1374, height: 877, text: text)
        textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        scrollView.layoutSubtreeIfNeeded()
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let rep = try #require(scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds))
        scrollView.cacheDisplay(in: scrollView.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("render-readme.png"))
    }

    @Test(arguments: [(1120.0, 800.0), (640.0, 520.0), (1800.0, 900.0)], [NSAppearance.Name.aqua, .darkAqua])
    func renderSample(size: (Double, Double), appearance: NSAppearance.Name) throws {
        guard let dir = Self.probeDirectory else { return }
        let sample = try String(contentsOf: dir.appendingPathComponent("fixtures/sample.md"), encoding: .utf8)
        let (scrollView, textView) = makeEditor(width: size.0, height: size.1, text: sample)
        scrollView.appearance = NSAppearance(named: appearance)
        scrollView.layoutSubtreeIfNeeded()
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        let rep = try #require(scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds))
        scrollView.cacheDisplay(in: scrollView.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let name = "render-\(Int(size.0))x\(Int(size.1))-\(appearance == .aqua ? "light" : "dark").png"
        try png.write(to: dir.appendingPathComponent(name))

        let inset = textView.textContainerInset
        let containerWidth = textView.textContainer!.size.width
        let line = "\(name): inset=\(inset) containerWidth=\(containerWidth) textViewWidth=\(textView.frame.width) bg=\(String(describing: textView.backgroundColor))\n"
        try line.append(to: dir.appendingPathComponent("render-metrics.txt"))
    }

    /// Heading concealment with the caret on the title (line 1, revealed) and
    /// on a body line (line 5, every heading concealed).
    @Test(arguments: [1, 5], [NSAppearance.Name.aqua, .darkAqua])
    func renderConcealment(cursorLine: Int, appearance: NSAppearance.Name) throws {
        guard let dir = Self.probeDirectory else { return }
        let sample = try String(contentsOf: dir.appendingPathComponent("fixtures/sample.md"), encoding: .utf8)
        let (scrollView, textView) = makeEditor(width: 1120, height: 800, text: sample)
        scrollView.appearance = NSAppearance(named: appearance)
        let lines = sample.components(separatedBy: "\n")
        let location = lines.prefix(cursorLine - 1).reduce(0) { $0 + $1.utf16.count + 1 }
        textView.setSelectedRange(NSRange(location: location, length: 0))
        scrollView.layoutSubtreeIfNeeded()
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        let rep = try #require(scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds))
        scrollView.cacheDisplay(in: scrollView.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let name = "render-conceal-line\(cursorLine)-\(appearance == .aqua ? "light" : "dark").png"
        try png.write(to: dir.appendingPathComponent(name))
    }

    /// Fenced blocks between prose, caret elsewhere: mono content, hidden
    /// fences, and a band that fits the theme.
    @Test
    func renderCodeBlock() throws {
        guard let dir = Self.probeDirectory else { return }
        let text = """
        # Code

        Settings are a text file:

        ```ini
        font.family = Test Tiempos Text
        measure = 655
        theme = slate
        ```

        And the build is two lines, with **markers** left literal:

        ```bash
        xcodegen generate
        xcodebuild -project Paper.xcodeproj -scheme Paper build  # not *italic*
        ```

        - a list after, to check spacing
        """
        let (scrollView, textView) = makeEditor(width: 1120, height: 700, text: text)
        textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        scrollView.layoutSubtreeIfNeeded()
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let rep = try #require(scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds))
        scrollView.cacheDisplay(in: scrollView.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("render-code.png"))
    }

    /// A hard-wrapped quote (one `>` per line) and a soft one, cursor
    /// elsewhere, to check the rule spans the block and the markers hide.
    @Test
    func renderQuotes() throws {
        guard let dir = Self.probeDirectory else { return }
        let text = """
        # Quotes

        > Determine whether Weekend Fund can serve as the principal investing
        > platform while Humanitas builds Media, its founder network, and its
        > operating capabilities.

        Plain paragraph between.

        > A single soft-wrapped quote line that runs long enough to wrap onto a second line inside the measure.

        - item after
        """
        let (scrollView, textView) = makeEditor(width: 1120, height: 600, text: text)
        textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        scrollView.layoutSubtreeIfNeeded()
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let rep = try #require(scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds))
        scrollView.cacheDisplay(in: scrollView.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("render-quotes.png"))
    }

    @Test(arguments: ["10k", "100k", "1m"])
    func profileRestyle(fixture: String) throws {
        guard let dir = Self.probeDirectory else { return }
        let text = try String(contentsOf: dir.appendingPathComponent("fixtures/\(fixture).md"), encoding: .utf8)
        let (_, textView) = makeEditor(width: 1120, height: 800, text: text)
        textView.setSelectedRange(NSRange(location: text.utf16.count / 2, length: 0))

        func milliseconds(since start: ContinuousClock.Instant) -> Double {
            let elapsed = ContinuousClock.now - start
            return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        }
        func list(_ values: [Double]) -> String { values.map { String(format: "%.1f", $0) }.joined(separator: ", ") }

        // Alternate with and without the concealment delegate on the same
        // view so the overhead is measured against the same document state.
        // The edit goes through the text view, so the restyle is the one a
        // keystroke gets: the chunk around the edit.
        let layoutManager = try #require(textView.layoutManager as? PaperLayoutManager)
        var concealing: [Double] = []
        var plain: [Double] = []
        for iteration in 0..<10 {
            let conceal = iteration.isMultiple(of: 2)
            layoutManager.delegate = conceal ? layoutManager : nil
            let start = ContinuousClock.now
            textView.insertText("x", replacementRange: textView.selectedRange())
            textView.syntaxStyler.applyEdited(to: textView)
            let ms = milliseconds(since: start)
            if conceal { concealing.append(ms) } else { plain.append(ms) }
        }
        layoutManager.delegate = layoutManager
        var full: [Double] = []
        for _ in 0..<3 {
            let start = ContinuousClock.now
            textView.syntaxStyler.apply(to: textView)
            full.append(milliseconds(since: start))
        }
        var line = "\(fixture): restyle per keystroke ms concealing = \(list(concealing)); plain = \(list(plain)); full pass = \(list(full))\n"

        // Moving the caret into a paragraph with marks invalidates layout
        // from there to the end of the text; the cost of a caret jump is
        // that relayout. Laid out once first, so the jumps measure only it.
        let container = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        var jumps: [Double] = []
        let length = textView.string.utf16.count
        for fraction in [0.1, 0.5, 0.9, 0.2] {
            let start = ContinuousClock.now
            textView.setSelectedRange(NSRange(location: Int(Double(length) * fraction), length: 0))
            layoutManager.ensureLayout(for: container)
            jumps.append(milliseconds(since: start))
        }
        line += "\(fixture): caret jump with relayout ms = \(list(jumps))\n"
        try line.append(to: dir.appendingPathComponent("profile.txt"))
    }
}

private extension String {
    func append(to url: URL) throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(utf8))
        } else {
            try write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
