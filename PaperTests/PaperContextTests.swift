import AppKit
import Testing
@testable import Paper

/// Paper's answers to the Ambient Context Protocol's two questions, from
/// editors built without a window, and the server over a real loopback
/// connection.
@MainActor
struct PaperContextTests {
    private func makeTextView(_ text: String, file: String? = nil) -> PaperTextView {
        let textView = PaperTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        textView.string = text
        if let file { textView.documentURL = URL(fileURLWithPath: "/tmp/essays/\(file)") }
        textView.syntaxStyler.apply(to: textView)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return textView
    }

    /// Types `string` at `location` the way the keyboard does.
    private func type(_ string: String, at location: Int, in textView: PaperTextView) {
        textView.textStorage?.replaceCharacters(in: NSRange(location: location, length: 0), with: string)
    }

    private let essay = "# Draft\n\nThe command line lasted thirty years.\n\nThen came the mouse.\n"

    @Test
    func currentListsTheDocumentsFrontToBackAndFocusesTheFrontOne() {
        let front = makeTextView(essay, file: "draft.md")
        let back = makeTextView("notes", file: "notes.md")
        let context = PaperContext(textViews: { [front, back] })

        let current = context.current()
        #expect(current.items.map(\.type) == ["document", "document"])
        #expect(current.items.map(\.title) == ["draft.md", "notes.md"])
        #expect(current.items[0].url == "file:///tmp/essays/draft.md")
        #expect(current.items[0].content == nil, "a document's text is not sent")
        #expect(current.focus == [current.items[0].id])
        // Asking again changes nothing.
        #expect(context.current() == current)
    }

    @Test
    func anUnsavedDocumentHasATitleAndNoAddress() {
        let context = PaperContext(textViews: { [makeTextView("unsaved")] })
        let item = context.current().items[0]
        #expect(item.title == "Untitled")
        #expect(item.url == nil)
    }

    @Test
    func withNothingOpenThereIsNothingToReport() {
        let context = PaperContext(textViews: { [] })
        #expect(context.current() == ContextCurrent())
    }

    @Test
    func aSelectionIsAnItemInsideItsDocument() throws {
        let front = makeTextView(essay, file: "draft.md")
        let sentence = (essay as NSString).range(of: "The command line lasted thirty years.")
        front.setSelectedRange(sentence)
        let context = PaperContext(textViews: { [front] })

        let current = context.current()
        #expect(current.items.count == 2)
        let selection = try #require(current.items.last)
        #expect(selection.type == "selection")
        #expect(selection.title == "Selection in draft.md")
        #expect(selection.parent == current.items[0].id)
        #expect(selection.content == [.text("The command line lasted thirty years.")])
        #expect(selection.locatable == true)
        #expect(selection.payload == ["lines": .object(["start": .integer(3), "end": .integer(3)])])
        #expect(current.focus == [selection.id])
        #expect(ContextResponder.isItemID(selection.id))
    }

    @Test
    func theSameSelectionKeepsItsIdAndADifferentOneGetsANewId() throws {
        let front = makeTextView(essay)
        let text = essay as NSString
        let context = PaperContext(textViews: { [front] })

        front.setSelectedRange(text.range(of: "thirty years"))
        let first = try #require(context.current().focus.first)
        #expect(context.current().focus == [first])

        front.setSelectedRange(text.range(of: "the mouse"))
        let second = try #require(context.current().focus.first)
        #expect(second != first)

        front.setSelectedRange(text.range(of: "thirty years"))
        #expect(context.current().focus == [first], "the earlier passage is still tracked under its id")
    }

    @Test
    func anIdStaysOnItsPassageWhenTextIsTypedAbove() throws {
        let front = makeTextView(essay)
        front.setSelectedRange((essay as NSString).range(of: "thirty years"))
        let context = PaperContext(textViews: { [front] })
        let id = try #require(context.current().focus.first)

        type("A new opening paragraph.\n\n", at: 0, in: front)
        guard case .live(let range) = front.trackedRanges.state(of: id) else {
            Issue.record("the passage was lost")
            return
        }
        #expect((front.string as NSString).substring(with: range) == "thirty years")
        #expect(range.location == (essay as NSString).range(of: "thirty years").location + 26)
    }

    @Test
    func undoAndRedoKeepTheIdOnItsPassage() throws {
        let front = makeTextView(essay)
        let undo = TestUndoHost()
        undo.attach(to: front)
        front.setSelectedRange((essay as NSString).range(of: "thirty years"))
        let context = PaperContext(textViews: { [front] })
        let id = try #require(context.current().focus.first)

        front.setSelectedRange(NSRange(location: 0, length: 0))
        front.insertText("Opening. ", replacementRange: NSRange(location: 0, length: 0))
        undo.undoManager.undo()
        undo.undoManager.redo()
        guard case .live(let range) = front.trackedRanges.state(of: id) else {
            Issue.record("the passage was lost")
            return
        }
        #expect((front.string as NSString).substring(with: range) == "thirty years")
    }

    @Test
    func deletingThePassageOrReloadingTheDocumentEndsTheId() throws {
        let front = makeTextView(essay)
        let passage = (essay as NSString).range(of: "thirty years")
        front.setSelectedRange(passage)
        let context = PaperContext(textViews: { [front] })
        let id = try #require(context.current().focus.first)

        front.textStorage?.replaceCharacters(in: passage, with: "")
        #expect(front.trackedRanges.state(of: id) == .gone)
        #expect(context.locate(id) == .gone(id))

        // A reload from disk replaces the whole text.
        front.setSelectedRange((front.string as NSString).range(of: "the mouse"))
        let second = try #require(context.current().focus.first)
        front.string = essay
        #expect(front.trackedRanges.state(of: second) == .gone)
    }

    @Test
    func anIdNeverIssuedIsNotAnAnswer() {
        let front = makeTextView(essay)
        let context = PaperContext(textViews: { [front] })
        _ = context.current()
        #expect(context.locate("sel-999") == nil)
        #expect(context.locate("doc-999") == nil)
        #expect(context.locate("nonsense") == nil)
    }

    @Test
    func aClosedDocumentsIdsAreGone() throws {
        final class Holder { var view: PaperTextView? }
        let holder = Holder()
        let context = PaperContext(textViews: { holder.view.map { [$0] } ?? [] })
        // AppKit holds a new view until the pool it was made in drains.
        let (document, selection): (String, String) = try autoreleasepool {
            let view = makeTextView(essay)
            view.setSelectedRange((essay as NSString).range(of: "thirty years"))
            holder.view = view
            let current = context.current()
            return (current.items[0].id, try #require(current.focus.first))
        }

        holder.view = nil
        #expect(context.locate(document) == .gone(document))
        #expect(context.locate(selection) == .gone(selection))
        #expect(context.current().items.isEmpty)
    }

    @Test
    func aLongSelectionIsCutAndMarked() throws {
        let long = String(repeating: "word ", count: 6_000)
        let front = makeTextView(long)
        front.setSelectedRange(NSRange(location: 0, length: (long as NSString).length))
        let context = PaperContext(textViews: { [front] })
        let selection = try #require(context.current().items.last)
        guard case .text(let sent)? = selection.content?.first else {
            Issue.record("no text block")
            return
        }
        #expect((sent as NSString).length == PaperContext.contentLimit)
        #expect(selection.payload?["truncated"] == .bool(true))
    }

    @Test
    func linesAreCountedFromOne() {
        let text = "a\nb\n\nd" as NSString
        #expect(PaperContext.line(at: 0, in: text) == 1)
        #expect(PaperContext.line(at: 1, in: text) == 1)
        #expect(PaperContext.line(at: 2, in: text) == 2)
        #expect(PaperContext.line(at: 5, in: text) == 4)
        #expect(PaperContext.line(at: 99, in: text) == 4)
    }

    // MARK: - Geometry

    @Test
    func aSelectionThatWrapsHasOneRectanglePerLine() throws {
        let line = String(repeating: "wrap ", count: 80)
        let front = makeTextView("first line\n\n\(line)\n")
        let text = front.string as NSString

        let short = front.lineRects(for: text.range(of: "first"))
        #expect(short.count == 1)
        let rect = try #require(short.first)
        #expect(rect.width > 10 && rect.height > 10)
        #expect(rect.minX >= front.textContainerOrigin.x)

        let wrapped = front.lineRects(for: text.range(of: line))
        #expect(wrapped.count >= 2)
        // Lines run down the page without overlapping.
        for (upper, lower) in zip(wrapped, wrapped.dropFirst()) {
            #expect(lower.minY >= upper.maxY - 0.5)
        }
        #expect(front.lineRects(for: NSRange(location: 0, length: 0)).isEmpty)
        #expect(front.lineRects(for: NSRange(location: text.length, length: 5)).isEmpty)
    }

    @Test
    func screenRectanglesTurnOverToATopLeftOrigin() {
        // A 100×20 rectangle whose bottom edge is 700 points up a display
        // 900 points tall has its top edge 180 points down.
        let rect = ContextGeometry.global(NSRect(x: 40, y: 700, width: 100, height: 20), primaryHeight: 900)
        #expect(rect == ContextRect(x: 40, y: 180, w: 100, h: 20))
        // A display above the primary one has negative y.
        let above = ContextGeometry.global(NSRect(x: -200, y: 1000, width: 10, height: 10), primaryHeight: 900)
        #expect(above == ContextRect(x: -200, y: -110, w: 10, h: 10))
    }

    // MARK: - Server

    private final class FixedProvider: ContextProvider {
        func current() -> ContextCurrent {
            ContextCurrent(focus: ["doc-1"], items: [ContextItem(id: "doc-1", type: "document", title: "draft.md")])
        }
        func locate(_ id: String) -> ContextLocation? { nil }
    }

    @Test
    func theServerAnswersOverLoopbackAndLeavesNothingBehind() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paper-context-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = FixedProvider()
        let server = ContextServer(
            provider: provider,
            app: .init(id: "org.example.editor", name: "Editor", version: "1.0"),
            directory: directory
        )
        server.start()

        // The descriptor appears once the listener is ready.
        let file = directory.appendingPathComponent("org.example.editor.\(ProcessInfo.processInfo.processIdentifier).json")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: file.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let descriptor = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let endpoint = try #require((descriptor["endpoint"] as? String).flatMap(URL.init))
        let token = try #require(descriptor["token"] as? String)
        #expect(endpoint.host == "127.0.0.1")
        #expect(descriptor["instance"] as? String == server.instance)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2026-07-28", forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("resources/read", forHTTPHeaderField: "Mcp-Method")
        request.setValue("ambient://current", forHTTPHeaderField: "Mcp-Name")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        {"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"ambient://current","_meta":{
        "io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
        """.utf8)
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let body = try #require(String(data: data, encoding: .utf8))
        #expect(body.contains("draft.md"))
        #expect(body.contains(try #require(server.instance)))

        request.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        let (_, refused) = try await session.data(for: request)
        #expect((refused as? HTTPURLResponse)?.statusCode == 401)

        server.stop()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!server.isRunning)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 2
        await #expect(throws: (any Error).self) { _ = try await session.data(for: request) }
    }
}
