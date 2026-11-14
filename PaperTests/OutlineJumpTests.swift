import AppKit
import Testing
@testable import Paper

/// Clicking an outline entry lands that heading at the reading line, in a
/// real window, on a long document with tables, fenced code, task lists,
/// and headings long enough to wrap once their syntax is revealed. In a
/// window the text view lays out lazily and grows its frame behind the
/// layout, which a windowless view never shows.
@MainActor
@Suite(.serialized)
struct OutlineJumpTests {
    private static let document: String = {
        var text = "# Plan: a long document with every kind of block\n\nOpening paragraph.\n\n"
        for section in 1...12 {
            text += "## \(section). Section number \(section)\n\n"
            text += "A paragraph of prose long enough to wrap across the measure once or twice, so the section has height of its own and the page has to scroll.\n\n"
            for sub in 1...3 {
                text += "### \(section).\(sub) `Paper/Editor/SomeLongFileName\(section)\(sub).swift` (changed: a long parenthetical that wraps when the syntax shows)\n\n"
                text += "| Column | Another column | Third |\n|---|---|---|\n| a cell with some words | another cell with more words in it | 3 |\n| short | a cell that wraps inside its column because it is long | 4 |\n\n"
                text += "```swift\n# not a heading\nlet value = \(section * sub)\n```\n\n"
                text += "- [x] T\(sub). A finished task with `code` in it.\n- [ ] T\(sub + 1). An open task that runs long enough to wrap onto a second line in the list.\n\n"
            }
        }
        return text
    }()

    private func makeWindow() -> (NSWindow, NSScrollView, PaperTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1300, height: 800),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let scrollView = PaperScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        let textView = PaperTextView()
        textView.string = Self.document
        textView.syntaxStyler.apply(to: textView)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .legacy
        scrollView.automaticallyAdjustsContentInsets = false
        window.contentView!.addSubview(scrollView)
        return (window, scrollView, textView)
    }

    /// Closes the window and empties the text: AppKit can keep a closed
    /// window's views a while, and every later settings change in the run
    /// would restyle this long document for nobody.
    private func close(_ window: NSWindow, _ textView: PaperTextView) {
        window.close()
        textView.string = ""
    }

    private func lineTop(of heading: OutlineHeading, in textView: PaperTextView) -> CGFloat {
        let layoutManager = textView.layoutManager!
        let glyph = layoutManager.glyphIndexForCharacter(at: heading.range.location)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textView.textContainerOrigin.y
    }

    /// Where the heading should be: at the reading line, or, when the
    /// document ends too soon for that, with the clip at the very end.
    private func check(_ heading: OutlineHeading, index: Int, model: OutlineModel, scrollView: NSScrollView, textView: PaperTextView, stage: String) {
        // The viewport in the text view's coordinates: its frame does not
        // start at the clip view's origin.
        let visible = textView.visibleRect
        let target = lineTop(of: heading, in: textView) - textView.textContainerInset.height
        // At the end AppKit may settle the clip a few points after the
        // jump (it re-constrains on the next tile), so the end is a band.
        let atEnd = visible.maxY >= textView.bounds.height - 8
        #expect(abs(visible.minY - target) < 1 || (atEnd && visible.minY < target), "\(stage): heading \(index) '\(heading.title)' top \(visible.minY) target \(target)")
        #expect(model.current == index, "\(stage): heading \(index) marked \(String(describing: model.current))")
    }

    /// How a click travels: at once, as under Reduce Motion, or eased.
    enum Motion: CaseIterable, Sendable {
        case instant, eased
    }

    private func makeModel(_ motion: Motion, scrollView: NSScrollView, textView: PaperTextView) -> OutlineModel {
        let model = OutlineModel()
        model.reducesMotion = { motion == .instant }
        model.attach(textView: textView, scrollView: scrollView)
        model.setActive(true)
        return model
    }

    /// Waits out an eased scroll, sampling the clip's origin and the mark
    /// on the way.
    @discardableResult
    private func land(_ model: OutlineModel, scrollView: NSScrollView) async throws -> [(y: CGFloat, current: Int?)] {
        var samples: [(y: CGFloat, current: Int?)] = []
        let start = ContinuousClock.now
        while model.isScrolling {
            samples.append((scrollView.contentView.bounds.minY, model.current))
            try #require(ContinuousClock.now - start < .seconds(3), "the scroll ends")
            try await Task.sleep(for: .milliseconds(8))
        }
        return samples
    }

    @Test(arguments: Motion.allCases)
    func jumpLandsEveryHeadingAtTheReadingLine(motion: Motion) async throws {
        let (window, scrollView, textView) = makeWindow()
        defer { close(window, textView) }
        let model = makeModel(motion, scrollView: scrollView, textView: textView)
        #expect(model.headings.count > 40)
        // Start where a reader would be: far down, the caret there.
        textView.setSelectedRange(NSRange(location: (Self.document as NSString).length - 10, length: 0))

        var eased = 0
        for (index, heading) in model.headings.enumerated() {
            model.jump(to: heading)
            #expect(model.current == index, "the mark moves with the click")
            if motion == .instant { #expect(!model.isScrolling, "Reduce Motion jumps at once") }
            if model.isScrolling { eased += 1 }
            let samples = try await land(model, scrollView: scrollView)
            #expect(samples.allSatisfy { $0.current == index }, "the mark holds on heading \(index) on the way")
            check(heading, index: index, model: model, scrollView: scrollView, textView: textView, stage: "after jump")
            textView.layoutManager!.ensureLayout(for: textView.textContainer!)
            try await Task.sleep(for: .milliseconds(20))
            check(heading, index: index, model: model, scrollView: scrollView, textView: textView, stage: "after layout")
            model.updateCurrent()
            #expect(model.current == index, "the scroll position agrees with the mark for heading \(index)")
        }
        if motion == .eased { #expect(eased > 40, "the jumps eased: \(eased)") }
    }

    /// The same, jumping backward from the end, where a lazily laid-out
    /// window has the least layout ahead of the target.
    @Test(arguments: Motion.allCases)
    func jumpBackwardFromTheEnd(motion: Motion) async throws {
        let (window, scrollView, textView) = makeWindow()
        defer { close(window, textView) }
        let model = makeModel(motion, scrollView: scrollView, textView: textView)
        for (index, heading) in model.headings.enumerated().reversed() {
            model.jump(to: heading)
            try await land(model, scrollView: scrollView)
            check(heading, index: index, model: model, scrollView: scrollView, textView: textView, stage: "after jump")
            try await Task.sleep(for: .milliseconds(20))
            check(heading, index: index, model: model, scrollView: scrollView, textView: textView, stage: "after a run-loop turn")
        }
    }

    /// An eased jump ends where the instant one does, passes through the
    /// points between, and keeps the mark on the clicked heading while
    /// the headings between go by.
    @Test
    func easedJumpTravelsToTheInstantJumpsEnd() async throws {
        let (window, scrollView, textView) = makeWindow()
        defer { close(window, textView) }
        let clip = scrollView.contentView
        let model = makeModel(.eased, scrollView: scrollView, textView: textView)
        let far = 30

        model.jump(to: model.headings[far], animated: false)
        #expect(!model.isScrolling)
        let instant = clip.bounds.minY
        model.jump(to: model.headings[0], animated: false)
        let start = clip.bounds.minY
        #expect(instant - start > 3 * clip.bounds.height, "a long way: \(instant - start)")

        model.jump(to: model.headings[far])
        #expect(model.isScrolling)
        #expect(model.current == far, "the mark is on the clicked heading from the start")
        #expect(abs(clip.bounds.minY - start) < 1, "the scroll starts from where the page was")
        #expect(textView.selectedRange().location == model.headings[far].contentRange.location)
        let samples = try await land(model, scrollView: scrollView)
        #expect(samples.allSatisfy { $0.current == far }, "the mark never passes through the headings between")
        let between = samples.filter { $0.y > start + 50 && $0.y < instant - 50 }
        #expect(between.count >= 3, "the page travels: \(samples.map(\.y))")
        #expect(samples.map(\.y) == samples.map(\.y).sorted(), "and never backs up or overshoots")
        #expect(samples.allSatisfy { $0.y <= instant + 0.5 })
        #expect(abs(clip.bounds.minY - instant) < 1, "eased \(clip.bounds.minY), instant \(instant)")
        #expect(model.current == far)
        try await Task.sleep(for: .milliseconds(50))
        #expect(abs(clip.bounds.minY - instant) < 1, "and stays there")
        #expect(model.current == far)
    }

    @Test
    func scrollDurationGrowsWithDistanceAndIsCapped() {
        #expect(OutlineModel.scrollDuration(distance: 10, viewport: 800) == 0.25)
        #expect(OutlineModel.scrollDuration(distance: 800, viewport: 800) == 0.25)
        #expect(abs(OutlineModel.scrollDuration(distance: 2400, viewport: 800) - 0.30) < 0.0001)
        #expect(OutlineModel.scrollDuration(distance: -2400, viewport: 800) == OutlineModel.scrollDuration(distance: 2400, viewport: 800))
        #expect(OutlineModel.scrollDuration(distance: 100_000, viewport: 800) == 0.35)
        #expect(OutlineModel.scrollDuration(distance: 100, viewport: 0) == 0.25)
        #expect(OutlineModel.scrollDurations.upperBound <= OutlineModel.maximumScrollDuration)
    }

    /// A second click mid-flight starts from where the page is and ends
    /// at the second heading; the first click's landing never happens.
    @Test
    func secondClickRetargetsFromWhereThePageIs() async throws {
        let (window, scrollView, textView) = makeWindow()
        defer { close(window, textView) }
        let clip = scrollView.contentView
        let model = makeModel(.eased, scrollView: scrollView, textView: textView)
        model.jump(to: model.headings[8], animated: false)
        let second = clip.bounds.minY
        model.jump(to: model.headings[40], animated: false)
        let first = clip.bounds.minY
        model.jump(to: model.headings[0], animated: false)
        let start = clip.bounds.minY

        model.jump(to: model.headings[40])
        try await Task.sleep(for: .milliseconds(120))
        let midway = clip.bounds.minY
        #expect(midway > start + 20 && midway < first - 20, "mid-flight at \(midway)")

        model.jump(to: model.headings[8])
        #expect(model.isScrolling)
        #expect(model.current == 8)
        #expect(abs(clip.bounds.minY - midway) < 1, "the second scroll starts where the first had got to")
        let samples = try await land(model, scrollView: scrollView)
        #expect(samples.allSatisfy { $0.current == 8 })
        #expect(abs(clip.bounds.minY - second) < 1, "landed at \(clip.bounds.minY), heading 8 is at \(second)")
        try await Task.sleep(for: .milliseconds(500))
        #expect(abs(clip.bounds.minY - second) < 1, "the first click's landing does not come back")
        #expect(model.current == 8)
    }

    /// The reader's own scroll takes the page back: the eased scroll
    /// stops and the mark follows the page again.
    @Test
    func aScrollWheelCancelsTheEasedJump() async throws {
        let (window, scrollView, textView) = makeWindow()
        defer { close(window, textView) }
        let clip = scrollView.contentView
        let model = makeModel(.eased, scrollView: scrollView, textView: textView)
        model.jump(to: model.headings[40], animated: false)
        let target = clip.bounds.minY
        model.jump(to: model.headings[0], animated: false)

        model.jump(to: model.headings[40])
        try await Task.sleep(for: .milliseconds(120))
        #expect(model.isScrolling)
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -2, wheel2: 0, wheel3: 0))
        scrollView.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        #expect(!model.isScrolling, "the wheel ends the eased scroll")
        let stopped = clip.bounds.minY
        #expect(stopped < target - 100, "short of the clicked heading: \(stopped) of \(target)")
        try await Task.sleep(for: .milliseconds(500))
        #expect(abs(clip.bounds.minY - stopped) < 60, "and the page stays where the reader left it: \(clip.bounds.minY)")
        let marked = model.current
        model.updateCurrent()
        #expect(model.current == marked, "the mark follows the page")
        #expect(model.current != 40)
    }
}
