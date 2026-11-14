import AppKit
import SwiftUI
import Testing
@testable import Paper

/// The outline's first entry sits on the baseline of the page's first
/// line. Measured in a real window that hosts the editor and the column
/// the way `DocumentView` does (the column in a top-trailing overlay, the
/// whole ignoring the safe area), with Paper's chrome and its title band
/// and without any band, as in full screen. The page's baseline comes
/// from the text view's layout; the entry's from the mark the column
/// reports, both in the window's coordinates.
@MainActor
@Suite(.serialized)
struct OutlineAlignmentTests {
    private final class Report: @unchecked Sendable {
        var entryBaseline: CGFloat?
    }

    /// `DocumentView`'s editor and outline, without the document.
    private struct Page: View {
        @State var text: String
        @ObservedObject var outline: OutlineModel
        let report: Report

        var body: some View {
            MarkdownEditor(text: $text, outline: outline)
                .overlay(alignment: .topTrailing) {
                    if outline.isVisible { OutlineColumn(model: outline) }
                }
                .frame(minWidth: 640, minHeight: 520)
                .ignoresSafeArea()
                .onPreferenceChange(OutlineColumn.FirstEntryBaseline.self) { [report] value in
                    report.entryBaseline = value
                }
        }
    }

    enum Chrome: CaseIterable, Sendable {
        /// Paper's window: the content under a transparent title bar and
        /// an empty toolbar, so a title band above the page.
        case windowed
        /// No title area at all, as in full screen.
        case bandless
    }

    private static func document(startingWith first: String) -> String {
        var text = first + "\n\nAn opening paragraph.\n\n"
        for section in 1...30 {
            text += "#### \(section). Section\n\nA paragraph of prose long enough to wrap across the measure once or twice, so the section has height of its own and the page has to scroll.\n\n"
        }
        return text
    }

    private struct Fixture {
        let window: NSWindow
        let host: NSView
        let textView: PaperTextView
        let scrollView: NSScrollView
        let model: OutlineModel
        let report: Report

        /// Closes the window and empties the text: AppKit can keep a
        /// closed window's views a while, and every later settings change
        /// in the run would restyle a long document for nobody.
        func close() {
            window.close()
            textView.string = ""
        }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let view = view as? T { return view }
        for subview in view.subviews {
            if let found = find(type, in: subview) { return found }
        }
        return nil
    }

    private func settle(_ fixture: Fixture) async throws {
        for _ in 0..<3 {
            fixture.window.layoutIfNeeded()
            fixture.host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
        }
    }

    private func makeFixture(_ text: String, chrome: Chrome, width: CGFloat = 1400) async throws -> Fixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 876),
            styleMask: chrome == .windowed ? [.titled, .resizable, .closable] : [.borderless],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        if chrome == .windowed { window.applyPaperChrome(minSize: NSSize(width: 640, height: 520)) }
        let model = OutlineModel(visible: true)
        let report = Report()
        let host = NSHostingView(rootView: Page(text: text, outline: model, report: report))
        window.contentView = host
        window.setContentSize(NSSize(width: width, height: 876))
        for _ in 0..<20 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            if find(PaperTextView.self, in: host) != nil, report.entryBaseline != nil { break }
        }
        let textView = try #require(find(PaperTextView.self, in: host))
        let scrollView = try #require(textView.enclosingScrollView)
        let fixture = Fixture(window: window, host: host, textView: textView, scrollView: scrollView, model: model, report: report)
        try await settle(fixture)
        return fixture
    }

    /// Below the top of the window's content, as SwiftUI's global space
    /// counts.
    private func fromTop(_ point: NSPoint, of view: NSView, in fixture: Fixture) -> CGFloat {
        let inHost = fixture.host.convert(point, from: view)
        return fixture.host.isFlipped ? inHost.y : fixture.host.bounds.height - inHost.y
    }

    /// The baseline of the page's first line where it is now, and where
    /// it is with the page scrolled to its top.
    private func pageBaseline(_ fixture: Fixture) throws -> (now: CGFloat, atTop: CGFloat) {
        let textView = fixture.textView
        let layoutManager = try #require(textView.layoutManager)
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: 0, length: 1))
        let y = textView.textContainerOrigin.y
            + layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY
            + layoutManager.location(forGlyphAt: 0).y
        let now = fromTop(NSPoint(x: 0, y: y), of: textView, in: fixture)
        return (now, now + textView.visibleRect.minY)
    }

    private func expectAligned(_ fixture: Fixture, _ stage: String) throws {
        let entry = try #require(fixture.report.entryBaseline, "\(stage): the column is showing")
        let page = try pageBaseline(fixture).atTop
        #expect(abs(entry - page) < 1, "\(stage): first entry baseline \(entry), page's first line \(page)")
    }

    @Test(arguments: Chrome.allCases, ["# Memo · inference", "A document that opens with a paragraph, not a heading."])
    func firstEntrySitsOnThePagesFirstBaseline(chrome: Chrome, first: String) async throws {
        let fixture = try await makeFixture(Self.document(startingWith: first), chrome: chrome)
        defer { fixture.close() }
        #expect(fixture.model.headings.count >= 30)
        let band = fixture.textView.textContainerInset.height - Appearance.topMargin
        #expect(chrome == .windowed ? band > 20 : band == 0, "the title band: \(band)")
        let page = try pageBaseline(fixture)
        #expect(abs(page.now - page.atTop) < 1, "the page opens at its top")
        try expectAligned(fixture, "at the top")

        // The label keeps its place above the first entry.
        #expect(OutlineColumn.entryOffset == OutlineColumn.labelHeight + OutlineColumn.labelGap + OutlineColumn.rowPadding)

        // The column does not scroll with the page.
        let before = try #require(fixture.report.entryBaseline)
        fixture.model.jump(to: fixture.model.headings[12], animated: false)
        try await settle(fixture)
        #expect(fixture.textView.visibleRect.minY > 500)
        #expect(fixture.report.entryBaseline == before, "the column stays put while the page scrolls")
        fixture.model.updateGeometry()
        try await settle(fixture)
        try expectAligned(fixture, "measured while scrolled")
    }

    /// The baseline follows the first line's styling, zoom and fonts, and
    /// the window's size.
    @Test
    func alignmentFollowsStylingZoomAndSize() async throws {
        let fixture = try await makeFixture(Self.document(startingWith: "Memo · inference"), chrome: .windowed)
        defer { fixture.close() }
        try expectAligned(fixture, "a paragraph first")
        let paragraph = try #require(fixture.report.entryBaseline)

        // The first line becomes a title: a larger font, a lower baseline.
        fixture.textView.insertText("# ", replacementRange: NSRange(location: 0, length: 0))
        fixture.textView.setSelectedRange(NSRange(location: (fixture.textView.string as NSString).length, length: 0))
        try await Task.sleep(for: OutlineModel.debounce + .milliseconds(150))
        try await settle(fixture)
        let title = try #require(fixture.report.entryBaseline)
        #expect(title > paragraph + 2, "the title's baseline is lower: \(title) against \(paragraph)")
        try expectAligned(fixture, "after the first line became a title")

        // Zoom, as a settings change reaches every text view.
        Zoom.withScale(1.5) {
            NotificationCenter.default.post(name: Configuration.didChangeNotification, object: nil)
        }
        try await settle(fixture)
        #expect(try #require(fixture.report.entryBaseline) > title + 10)
        try expectAligned(fixture, "zoomed to 150%")
        NotificationCenter.default.post(name: Configuration.didChangeNotification, object: nil)
        try await settle(fixture)
        try expectAligned(fixture, "back at 100%")

        fixture.window.setContentSize(NSSize(width: 1500, height: 700))
        try await settle(fixture)
        try expectAligned(fixture, "after a resize")
    }

    /// The column lies over the editor's whole frame; outside its entries
    /// a click still reaches the text.
    @Test
    func theColumnLeavesThePageToTheTextView() async throws {
        let fixture = try await makeFixture(Self.document(startingWith: "# Memo"), chrome: .windowed)
        defer { fixture.close() }
        let inText = fixture.host.convert(
            NSPoint(x: fixture.textView.textContainerOrigin.x + 40, y: fixture.textView.textContainerOrigin.y + 200),
            from: fixture.textView
        )
        let hit = try #require(fixture.host.hitTest(fixture.host.superview?.convert(inText, from: fixture.host) ?? inText))
        #expect(hit === fixture.textView || hit.isDescendant(of: fixture.scrollView), "hit \(type(of: hit))")
    }
}
