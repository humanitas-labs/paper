import AppKit

/// Paper as a provider for the Ambient Context Protocol: which documents
/// are open, what is selected in the front one, and where a document or
/// a selection is on screen.
///
/// Everything is answered from the windows as they stand; nothing is read
/// from disk. A document's text is not sent: an agent gets the file's
/// URL and the selection, and reads the file itself if it needs more.
@MainActor
final class PaperContext: ContextProvider {
    static let shared = PaperContext()

    /// The most selected text sent, in UTF-16 units; longer is cut and
    /// marked.
    static let contentLimit = 20_000

    /// The open editors, front to back.
    private let textViews: @MainActor () -> [PaperTextView]
    private var counter = 0
    /// Every id issued this run and the editor it belongs to. An id whose
    /// editor has closed is gone; an id not here was never issued.
    private var issued: [String: Editor] = [:]
    private var documents: [(id: String, editor: Editor)] = []
    private var windows: [(id: String, editor: Editor)] = []
    private var server: ContextServer?

    private final class Editor {
        weak var view: PaperTextView?
        init(_ view: PaperTextView) { self.view = view }
    }

    init(textViews: @escaping @MainActor () -> [PaperTextView] = PaperContext.openTextViews) {
        self.textViews = textViews
    }

    // MARK: - Lifecycle

    /// Starts or stops the server to match the setting, now and whenever
    /// the configuration changes; one call at launch.
    func start(store: ConfigurationStore = .shared) {
        // A crashed run may have left a descriptor; it goes even when the
        // setting is now off and no server will start to clear it.
        ContextDescriptor.removeStale(
            bundleID: Bundle.main.bundleIdentifier ?? "org.humanitas.Paper",
            pid: ProcessInfo.processInfo.processIdentifier,
            in: ContextDescriptor.defaultDirectory
        )
        sync(store.current)
        NotificationCenter.default.addObserver(
            forName: Configuration.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { PaperContext.shared.sync(ConfigurationStore.shared.current) }
        }
    }

    func sync(_ configuration: Configuration) {
        if configuration.ambientContext {
            guard server == nil else { return }
            let info = Bundle.main.infoDictionary
            let server = ContextServer(provider: self, app: .init(
                id: Bundle.main.bundleIdentifier ?? "org.humanitas.Paper",
                name: "Paper",
                version: info?["CFBundleShortVersionString"] as? String ?? "0"
            ))
            server.start()
            self.server = server
        } else {
            stop()
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    // MARK: - current

    /// The app, a window for each open editor front to back, the
    /// document in it, and the selected text in the front one:
    ///
    ///     Application → Window → Document [markdown] → Text, selected
    ///
    /// The front window and its document are the focus path. A window
    /// that is minimized or behind another tab is marked not visible.
    func current() -> ContextElement {
        let views = textViews()
        documents.removeAll { $0.editor.view == nil }
        windows.removeAll { $0.editor.view == nil }

        var root = ContextElement(id: "app", role: .application, title: "Paper")
        for (index, view) in views.enumerated() {
            let front = index == 0
            var document = ContextElement(
                id: documentID(for: view), role: .document, subrole: "markdown", title: Self.title(of: view),
                url: view.documentURL?.absoluteString, focused: front
            )
            if front, let selection = selection(in: view) { document.children = [selection] }
            var window = ContextElement(id: windowID(for: view), role: .window, focused: front, children: [document])
            if let shown = view.window, !shown.isVisible || shown.isMiniaturized { window.visible = false }
            root.children.append(window)
        }
        return root
    }

    /// The selected text in `view` as an element, or nil when nothing is
    /// selected. A passage keeps the id it was first given.
    private func selection(in view: PaperTextView) -> ContextElement? {
        let selection = view.selectedRange()
        let text = view.string as NSString
        guard selection.length > 0, NSMaxRange(selection) <= text.length else { return nil }

        let id: String
        if let known = view.trackedRanges.id(for: selection) {
            id = known
        } else {
            id = mint("sel", for: view)
            view.trackedRanges.track(selection, as: id)
        }
        let sent = NSRange(location: selection.location, length: min(selection.length, Self.contentLimit))
        let startLine = Self.line(at: selection.location, in: text)
        let inside = NSRange(location: selection.location, length: max(selection.length - 1, 0))
        var attributes: [String: ContextValue] = ["lines": .object([
            "start": .integer(startLine),
            "end": .integer(startLine + Self.newlines(in: inside, of: text)),
        ])]
        if sent.length < selection.length { attributes["truncated"] = .bool(true) }
        return ContextElement(
            id: id, role: .text,
            content: [.text(text.substring(with: text.rangeOfComposedCharacterSequences(for: sent)))],
            selected: true, attributes: attributes
        )
    }

    // MARK: - locate

    func locate(_ id: String) -> ContextLocation? {
        guard let editor = issued[id] else { return nil }
        guard let view = editor.view, let window = view.window else { return .gone(id) }
        let onScreen = window.isVisible && !window.isMiniaturized

        if id.hasPrefix("doc-") || id.hasPrefix("win-") {
            guard onScreen else { return ContextLocation(id: id, state: .offscreen, window: window.windowNumber) }
            return ContextLocation(
                id: id, state: .visible,
                rects: [ContextGeometry.global(window.frame)],
                window: window.windowNumber
            )
        }
        guard case .live(let range) = view.trackedRanges.state(of: id) else { return .gone(id) }
        let rects = onScreen ? view.screenRects(for: range) : []
        guard !rects.isEmpty else { return ContextLocation(id: id, state: .offscreen, window: window.windowNumber) }
        return ContextLocation(
            id: id, state: .visible,
            rects: rects.map(ContextGeometry.global),
            window: window.windowNumber,
            avoid: view.screenTextColumn().map(ContextGeometry.global),
            edge: .right
        )
    }

    // MARK: - Ids

    private func mint(_ kind: String, for view: PaperTextView) -> String {
        counter += 1
        let id = "\(kind)-\(counter)"
        issued[id] = Editor(view)
        return id
    }

    private func documentID(for view: PaperTextView) -> String {
        if let known = documents.first(where: { $0.editor.view === view }) { return known.id }
        let id = mint("doc", for: view)
        if let editor = issued[id] { documents.append((id, editor)) }
        return id
    }

    private func windowID(for view: PaperTextView) -> String {
        if let known = windows.first(where: { $0.editor.view === view }) { return known.id }
        let id = mint("win", for: view)
        if let editor = issued[id] { windows.append((id, editor)) }
        return id
    }

    // MARK: - Reading the app

    /// The editors in the app's windows, front to back, then any the
    /// window order leaves out (a background tab, a minimized window).
    static func openTextViews() -> [PaperTextView] {
        var views: [PaperTextView] = []
        for window in NSApp.orderedWindows + NSApp.windows {
            guard window.isVisible || window.isMiniaturized || window.tabbedWindows != nil,
                  let view = window.contentView.flatMap(textView(in:)),
                  !views.contains(where: { $0 === view }) else { continue }
            views.append(view)
        }
        return views
    }

    private static func textView(in view: NSView) -> PaperTextView? {
        if let found = view as? PaperTextView { return found }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }

    private static func title(of view: PaperTextView) -> String {
        if let url = view.documentURL { return url.lastPathComponent }
        if let title = view.window?.title, !title.isEmpty { return title }
        return "Untitled"
    }

    /// The 1-based line holding the UTF-16 unit at `location`.
    static func line(at location: Int, in text: NSString) -> Int {
        1 + newlines(in: NSRange(location: 0, length: min(max(location, 0), text.length)), of: text)
    }

    /// How many line feeds `range` holds. One native pass over the
    /// range, so a selection at the end of a long document does not cost
    /// a search per line.
    static func newlines(in range: NSRange, of text: NSString) -> Int {
        let start = min(max(range.location, 0), text.length)
        let end = min(max(NSMaxRange(range), start), text.length)
        return lineFeed.numberOfMatches(
            in: text as String, options: [], range: NSRange(location: start, length: end - start)
        )
    }

    private static let lineFeed = try! NSRegularExpression(pattern: "\n", options: [.ignoreMetacharacters])
}

/// Screen geometry in the protocol's terms.
enum ContextGeometry {
    /// An AppKit screen rectangle, whose origin is the bottom left of the
    /// primary display, as the protocol's: origin at that display's top
    /// left, y increasing downward.
    @MainActor
    static func global(_ rect: NSRect) -> ContextRect {
        global(rect, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    static func global(_ rect: NSRect, primaryHeight: CGFloat) -> ContextRect {
        ContextRect(x: rect.minX, y: primaryHeight - rect.maxY, w: rect.width, h: rect.height)
    }
}

extension PaperTextView {
    /// One rectangle per line of `range`, in the view's own coordinates.
    /// Text the editor conceals, such as Markdown syntax away from the
    /// caret, has no width and gives no rectangle.
    func lineRects(for range: NSRange) -> [NSRect] {
        guard let layoutManager, let container = textContainer, let storage = textStorage,
              range.length > 0, NSMaxRange(range) <= storage.length else { return [] }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let origin = textContainerOrigin
        var rects: [NSRect] = []
        // Line by line: the layout manager's own enclosing rectangles
        // merge full lines into one block.
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
            let part = NSIntersectionRange(lineGlyphs, glyphs)
            guard part.length > 0 else { return }
            let rect = layoutManager.boundingRect(forGlyphRange: part, in: container)
            guard rect.width >= 0.5, rect.height >= 0.5 else { return }
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        return rects
    }

    /// The visible part of each line of `range`, in AppKit screen
    /// coordinates; empty when none of it is in view.
    func screenRects(for range: NSRange) -> [NSRect] {
        guard let window else { return [] }
        let visible = visibleRect
        return lineRects(for: range).compactMap { rect in
            let shown = rect.intersection(visible)
            guard !shown.isNull, shown.width >= 0.5, shown.height >= 0.5 else { return nil }
            return window.convertToScreen(convert(shown, to: nil))
        }
    }

    /// The visible part of the column the text is set in, in AppKit
    /// screen coordinates: what a host should try not to cover.
    func screenTextColumn() -> NSRect? {
        guard let window, let container = textContainer else { return nil }
        let visible = visibleRect
        let column = NSRect(x: textContainerOrigin.x, y: visible.minY, width: container.size.width, height: visible.height)
            .intersection(visible)
        guard !column.isNull, column.width >= 1, column.height >= 1 else { return nil }
        return window.convertToScreen(convert(column, to: nil))
    }
}
