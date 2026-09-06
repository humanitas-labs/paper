import SwiftUI

@main
struct PaperApp: App {
    /// Observed so scene-level values such as the default window size
    /// follow the configuration.
    @ObservedObject private var store = ConfigurationStore.shared
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    init() {
        // `paper --set-default` runs this executable directly; answer and
        // exit before the application, and any window, comes up.
        if DefaultApplication.requestedOnCommandLine { DefaultApplication.runFromCommandLine() }
        ConfigurationStore.shared.start()
    }

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { configuration in
            DocumentView(document: configuration.$document, fileURL: configuration.fileURL)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: store.current.windowWidth, height: store.current.windowHeight)
        .commands {
            // Replacing the toolbar group empties SwiftUI's View menu, which
            // also drops AppKit's Enter Full Screen item and its ⌃⌘F shortcut.
            // Provide the toggle explicitly so the shortcut keeps working.
            // Markdown emphasis in the Format menu; AppKit's rich-text
            // items would set font traits the document cannot keep.
            CommandGroup(replacing: .textFormatting) {
                Button("Bold") { NSApp.sendAction(#selector(PaperTextView.toggleBold(_:)), to: nil, from: nil) }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Italic") { NSApp.sendAction(#selector(PaperTextView.toggleItalic(_:)), to: nil, from: nil) }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Underline") { NSApp.sendAction(#selector(PaperTextView.toggleUnderline(_:)), to: nil, from: nil) }
                    .keyboardShortcut("u", modifiers: .command)
                Button("Strikethrough") { NSApp.sendAction(#selector(PaperTextView.toggleStrikethrough(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Button("Code") { NSApp.sendAction(#selector(PaperTextView.toggleCode(_:)), to: nil, from: nil) }
                    .keyboardShortcut("e", modifiers: .command)
                Divider()
                Button("Add Link") { NSApp.sendAction(#selector(PaperTextView.insertLink(_:)), to: nil, from: nil) }
                    .keyboardShortcut("k", modifiers: .command)
            }
            // The path, as plain text, for pasting into a prompt; Finder's key.
            CommandGroup(after: .saveItem) {
                Button("Copy Path") { NSApp.sendAction(#selector(PaperTextView.copyPath(_:)), to: nil, from: nil) }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Button("Export as PDF…") { NSApp.sendAction(#selector(PaperTextView.exportPDF(_:)), to: nil, from: nil) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            // SwiftUI's document app leaves the Find submenu out of Edit, so
            // nothing would reach find. Built here; the scroll view that
            // owns the find pill answers (`PaperScrollView`).
            CommandGroup(after: .pasteboard) {
                Menu("Find") {
                    Button("Find…") { NSApp.sendAction(#selector(PaperScrollView.showFind(_:)), to: nil, from: nil) }
                        .keyboardShortcut("f", modifiers: .command)
                    Button("Find Next") { NSApp.sendAction(#selector(PaperScrollView.findNext(_:)), to: nil, from: nil) }
                        .keyboardShortcut("g", modifiers: .command)
                    Button("Find Previous") { NSApp.sendAction(#selector(PaperScrollView.findPrevious(_:)), to: nil, from: nil) }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                    // ⌘E is Code, as documented; this one goes without a key.
                    Button("Use Selection for Find") { NSApp.sendAction(#selector(PaperScrollView.useSelectionForFind(_:)), to: nil, from: nil) }
                    Button("Jump to Selection") { NSApp.sendAction(Selector(("centerSelectionInVisibleRect:")), to: nil, from: nil) }
                        .keyboardShortcut("j", modifiers: .command)
                }
            }
            CommandGroup(replacing: .toolbar) {
                Button("Toggle Full Screen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
                Divider()
                // A lens for the monitor at hand: the whole page scales
                // together and the setting stays on this machine.
                Button("Zoom In") { Zoom.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { Zoom.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { Zoom.reset() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

private struct DocumentView: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?
    /// Observed so the SwiftUI canvas and label follow theme changes.
    @ObservedObject private var store = ConfigurationStore.shared
    @ObservedObject private var updates = UpdateCheck.observed
    @State private var watcher: FileWatcher?

    var body: some View {
        MarkdownEditor(text: $document.text, fileURL: fileURL)
            .background(Color(nsColor: Appearance.canvas))
            .background(WindowConfigurator())
            .overlay(alignment: .topLeading) { FileBadge(fileURL: fileURL) }
            .overlay(alignment: .topTrailing) { ZoomBadge() }
            // A release installs while someone writes; the badge that asks
            // for the restart sits in the document's corner as it does in
            // the welcome window, which a writer may never open.
            .overlay(alignment: .bottomLeading) {
                if let release = updates.available, updates.justUpdatedTo == nil {
                    UpdateBadge(release: release)
                }
            }
            .overlay(alignment: .top) { UpdateToast().ignoresSafeArea(.container, edges: .top) }
            .frame(minWidth: 640, minHeight: 520)
            .ignoresSafeArea()
            .onChange(of: fileURL, initial: true) { _, url in
                // The welcome window lists recents; SwiftUI's document
                // controller does not note them itself.
                if let url { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
                watcher?.cancel()
                watcher = url.map { url in
                    FileWatcher(url: url) { reload(from: url) }
                }
            }
            .onDisappear {
                watcher?.cancel()
                watcher = nil
            }
    }

    /// Follows edits other programs save to the open file. A buffer with
    /// unsaved changes keeps them and surfaces the conflict on save, as
    /// before; a clean buffer adopts the disk content in place.
    private func reload(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let fresh = try? MarkdownDocument(data: data),
              fresh.text != document.text else { return }
        let nsDocument = NSDocumentController.shared.document(for: url)
        if nsDocument?.isDocumentEdited == true { return }
        document.text = fresh.text
        // The binding write marks the document edited; it now matches the
        // disk, so clear the change count and adopt the file's modification
        // date, keeping the next save quiet about the external edit.
        DispatchQueue.main.async {
            // A keystroke landing between the adoption above and this
            // deferred reset is a real edit; clearing then would mark it
            // clean and close without the unsaved-change protection. Only
            // a buffer still matching what was adopted is clean.
            guard document.text == fresh.text else { return }
            nsDocument?.updateChangeCount(.changeCleared)
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate {
                nsDocument?.fileModificationDate = date
            }
        }
    }
}
