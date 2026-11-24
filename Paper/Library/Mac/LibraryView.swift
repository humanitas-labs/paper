import AppKit
import SwiftUI

/// A folder opened in Paper, as the iPhone library shows one: its folders as
/// folder cards, then its notes as miniatures of the page, newest first, in
/// a grid that scrolls down and never pans. A click walks into a folder or
/// opens a note in its own window, as in Spatial. Back and forward in the
/// window's toolbar walk back out, as far as the folder opened.
struct LibraryView: View {
    /// Where the library is and has been; the window's toolbar drives it too.
    @ObservedObject var navigation: LibraryNavigation
    @State private var listing = FolderListing()
    @State private var loaded = false
    @State private var watcher: FolderWatcher?
    /// The menu a right click opened, while it is up.
    @State private var menu: LibraryMenuRequest?
    /// Where each card on screen is, in the window, to tell what a right
    /// click landed on.
    @State private var cardFrames: [URL: CGRect] = [:]
    /// The cards picked, by dragging a rectangle across them or by
    /// ⌘-clicking. The toast at the foot of the window acts on them; a
    /// click anywhere else lets go of them.
    @State private var selection: Set<URL> = []
    /// The rectangle being dragged, in the window's content.
    @State private var marquee: CGRect?
    /// What was picked when the drag began, kept when ⌘ is held.
    @State private var marqueeBase: Set<URL> = []
    /// A drag that ends over a card must not also click it.
    @State private var dragEnded = Date.distantPast
    /// Where the toast is, so a click on it is not a click off the cards.
    @State private var toastFrame = CGRect.zero
    @State private var renaming = false
    @State private var renameText = ""
    /// False only for an offscreen snapshot, which cannot draw a scroll view.
    private let scrolls: Bool

    private var folder: URL { navigation.folder }

    /// `listing`, when given, is shown at once instead of loading first.
    init(navigation: LibraryNavigation, listing: FolderListing? = nil, scrolls: Bool = true) {
        self.navigation = navigation
        self.scrolls = scrolls
        if let listing {
            _listing = State(initialValue: listing)
            _loaded = State(initialValue: true)
        }
    }

    private let folderColumns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 18)]
    private let noteColumns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 18)]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if scrolls {
                    ScrollView { page }
                } else {
                    page.frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        // A click on empty space lets go of what is picked; cards take
        // their own clicks first.
        .background {
            LibraryPalette.background.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { deselect() }
        }
        // A drag anywhere below the toolbar draws the rubber band.
        .contentShape(Rectangle())
        .simultaneousGesture(marqueeGesture)
        .overlay(MarqueeLayer(rect: marquee))
        .overlay(alignment: .bottom) {
            if !selection.isEmpty {
                LibrarySelectionToast(
                    count: selection.count, move: moveSelection,
                    rename: selection.count == 1 ? { beginRename() } : nil,
                    trash: trashSelection
                )
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { toastFrame = $0 }
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(LibraryMotion.selectionSpring, value: selection.isEmpty)
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Rename", action: renameSelection)
            Button("Cancel", role: .cancel) {}
        }
        .overlay(LibraryMenuLayer(request: $menu))
        .onReceive(navigation.secondaryClicks) { secondaryClick(at: $0) }
        .onReceive(navigation.primaryClicks) { primaryClick(at: $0) }
        // Spatial's style of pointer over the whole library.
        .pointerStyle(LibraryPointer.style)
        .background(keyCommands)
        .task(id: folder) {
            selection.removeAll()
            cardFrames.removeAll()
            await reload()
            watch()
        }
        .onDisappear {
            watcher?.cancel()
            watcher = nil
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 32) {
            contents
        }
        .padding(.horizontal, 32)
        .padding(.top, 12)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var contents: some View {
        if !listing.folders.isEmpty {
            LazyVGrid(columns: folderColumns, alignment: .leading, spacing: 18) {
                ForEach(listing.folders) { item in
                    FolderCard(folder: item, selected: selection.contains(item.url))
                        .background(FolderCard.shadow)
                        .modifier(CardClick { click(item.url) { go(to: item.url) } })
                        .modifier(CardFrame(url: item.url, frames: $cardFrames))
                        .transition(LibraryMotion.itemTransition)
                }
            }
        }
        if !listing.notes.isEmpty {
            LazyVGrid(columns: noteColumns, alignment: .leading, spacing: 18) {
                ForEach(listing.notes) { item in
                    LibraryNoteTile(note: item, selected: selection.contains(item.url))
                        .modifier(NoteShadow())
                        .modifier(CardClick(label: item.url.lastPathComponent) { click(item.url) { openNote(item.url) } })
                        .modifier(CardFrame(url: item.url, frames: $cardFrames))
                        .transition(LibraryMotion.itemTransition)
                }
            }
        }
        if loaded, listing.folders.isEmpty, listing.notes.isEmpty {
            Text("No notes here yet.")
                .foregroundStyle(LibraryPalette.secondaryLabel)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 120)
        }
    }

    // MARK: Selection

    /// A click opens a card, as in Spatial, and lets go of anything
    /// picked. Only a ⌘-click or a ⇧-click picks or lets go of the card
    /// itself.
    private func click(_ url: URL, open: () -> Void) {
        guard Date().timeIntervalSince(dragEnded) > 0.15 else { return }
        if !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty {
            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
        } else {
            deselect()
            open()
        }
    }

    /// The rubber band: every card it touches is picked, on top of what
    /// was picked before when ⌘ is held.
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { value in
                guard menu == nil else { return }
                if marquee == nil {
                    let adding = !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty
                    marqueeBase = adding ? selection : []
                }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y)
                )
                marquee = rect
                let touched = cardFrames.filter { $0.value.intersects(rect) }.map(\.key)
                selection = marqueeBase.union(touched)
            }
            .onEnded { _ in
                guard marquee != nil else { return }
                marquee = nil
                dragEnded = Date()
            }
    }

    private func deselect() { selection.removeAll() }

    /// A click on empty space lets go of what is picked. Cards and the
    /// toast answer their own clicks; a menu or a dialog that is up takes
    /// the click for itself.
    private func primaryClick(at point: CGPoint) {
        guard !selection.isEmpty, menu == nil, !renaming else { return }
        // With ⌘ or ⇧ held, the press may begin a drag that adds to it.
        guard NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
        guard !toastFrame.contains(point), !cardFrames.values.contains(where: { $0.contains(point) }) else { return }
        deselect()
    }

    private func selectAll() {
        selection = Set(listing.folders.map(\.url) + listing.notes.map(\.url))
    }

    /// To the Trash, recoverable; the folder watcher takes the cards away.
    private func trashSelection() {
        guard !selection.isEmpty else { return }
        NSWorkspace.shared.recycle(Array(selection)) { _, _ in }
        deselect()
    }

    /// Asks where, in a folder panel that opens on the folder shown and
    /// can make a new folder, then moves what is picked there.
    private func moveSelection() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Move"
        panel.message = selection.count == 1 ? "Move this item to:" : "Move \(selection.count) items to:"
        guard panel.runModal() == .OK, let destination = panel.url?.standardizedFileURL else { return }
        for url in selection {
            // A folder cannot go into itself or below itself.
            let path = url.standardizedFileURL.path
            guard destination.path != path, !destination.path.hasPrefix(path + "/") else { continue }
            try? NoteFile.move(url, into: destination)
        }
        deselect()
        Task { await reload() }
    }

    private func beginRename() {
        guard let url = selection.first else { return }
        let isFolder = listing.folders.contains { $0.url == url }
        renameText = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        renaming = true
    }

    private func renameSelection() {
        guard let url = selection.first else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, !name.hasPrefix(".") else { return }
        let isFolder = listing.folders.contains { $0.url == url }
        _ = try? NoteFile.rename(url, to: name, isFolder: isFolder)
        deselect()
        Task { await reload() }
    }

    // MARK: Menu

    /// A right click closes an open menu; otherwise it opens the menu of
    /// the card under it, or of the folder shown on empty space.
    private func secondaryClick(at point: CGPoint) {
        if menu != nil {
            withAnimation(LibraryMenuLayer.wash) { menu = nil }
            return
        }
        if let url = cardFrames.first(where: { $0.value.contains(point) })?.key {
            let isFolder = listing.folders.contains { $0.url == url }
            showMenu(at: point, items: items(for: url, isFolder: isFolder))
        } else {
            showMenu(at: point, items: emptySpaceItems)
        }
    }

    private func showMenu(at point: CGPoint, items: [LibraryMenuItem]) {
        withAnimation(LibraryMenuLayer.wash) {
            menu = LibraryMenuRequest(point: point, items: items)
        }
    }

    private func items(for url: URL, isFolder: Bool) -> [LibraryMenuItem] {
        [
            LibraryMenuItem(title: "Open", glyph: OpenGlyph()) {
                isFolder ? go(to: url) : openNote(url)
            },
            LibraryMenuItem(title: "Reveal in Finder", glyph: RevealGlyph()) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            LibraryMenuItem(title: "Copy Path", glyph: CopyGlyph()) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            },
            LibraryMenuItem(title: "Move to Trash", glyph: TrashGlyph()) {
                // Recoverable; the folder watcher takes the card away.
                NSWorkspace.shared.recycle([url]) { _, _ in }
            },
        ]
    }

    private var emptySpaceItems: [LibraryMenuItem] {
        [
            LibraryMenuItem(title: "New Note", glyph: ComposeGlyph()) { newNote() },
            LibraryMenuItem(title: "New Folder", glyph: NewFolderGlyph()) { newFolder() },
            LibraryMenuItem(title: "Reveal in Finder", glyph: RevealGlyph()) {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            },
        ]
    }

    /// An empty `Untitled.md`, numbered when the name is taken, opened at
    /// once in its own window.
    private func newNote() {
        let url = LibraryNames.unused("Untitled", extension: "md", in: folder)
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { return }
        openNote(url)
    }

    /// `Untitled Folder`, numbered when taken, as Finder names one.
    private func newFolder() {
        let url = LibraryNames.unused("Untitled Folder", extension: "", in: folder)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// ⌘↑ to the enclosing folder, ⌘[ back and ⌘] forward, as in Finder.
    /// The buttons are hidden; only their keys act.
    private var keyCommands: some View {
        ZStack {
            Button("Enclosing Folder") { goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Back") { goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { goForward() }
                .keyboardShortcut("]", modifiers: .command)
            Button("Select All") { selectAll() }
                .keyboardShortcut("a", modifiers: .command)
            Button("Deselect") { deselect() }
                .keyboardShortcut(.escape, modifiers: [])
            Button("Move to Trash") { trashSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Navigation

    private func go(to target: URL) { navigation.go(to: target) }
    private func goUp() { navigation.goUp() }
    private func goBack() { navigation.goBack() }
    private func goForward() { navigation.goForward() }

    /// Opens a note in its own window, grown out of its card when the
    /// card is on screen.
    private func openNote(_ url: URL) {
        var card: NSRect?
        if let frame = cardFrames[url], let window = navigation.window, let content = window.contentView {
            // The card's frame is measured from the content's top left.
            let inContent = NSRect(
                x: frame.minX, y: content.isFlipped ? frame.minY : content.bounds.height - frame.maxY,
                width: frame.width, height: frame.height
            )
            card = window.convertToScreen(content.convert(inContent, to: nil))
        }
        NoteOpenAnimation.open(url, from: card, cardColor: NSColor(LibraryPalette.card), library: navigation.window)
    }

    // MARK: Loading

    private func reload() async {
        let folder = folder
        let fresh = await Task.detached { FolderListing.load(folder, isDefaultRoot: false) }.value
        guard folder == self.folder else { return }
        if loaded {
            withAnimation(LibraryMotion.itemSpring) { listing = fresh }
        } else {
            listing = fresh
        }
        loaded = true
    }

    private func watch() {
        watcher?.cancel()
        watcher = FolderWatcher(folder: folder) {
            Task { await reload() }
        }
    }
}

/// A note's card with its miniature, drawn when the card first shows and
/// again whenever the note or the appearance changes.
private struct LibraryNoteTile: View {
    let note: FolderListing.Note
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var miniature: NSImage?

    init(note: FolderListing.Note, selected: Bool) {
        self.note = note
        self.selected = selected
    }

    /// A miniature already drawn shows from the first frame.
    private var shown: NSImage? {
        miniature ?? NoteMiniature.cached(NoteMiniature.key(for: note.url, modified: note.modified, dark: colorScheme == .dark))
    }

    var body: some View {
        NoteCard(note: note, selected: selected, miniature: shown.map { Image(nsImage: $0) })
            .task(id: NoteMiniature.key(for: note.url, modified: note.modified, dark: colorScheme == .dark)) {
                let key = NoteMiniature.key(for: note.url, modified: note.modified, dark: colorScheme == .dark)
                if let cached = NoteMiniature.cached(key) {
                    miniature = cached
                    return
                }
                // One card per turn of the run loop, so a folder of many
                // notes fills in without holding up scrolling.
                await Task.yield()
                guard !Task.isCancelled else { return }
                miniature = NoteMiniature.image(
                    for: note.url, modified: note.modified, dark: colorScheme == .dark,
                    background: NSColor(LibraryPalette.card)
                )
            }
    }
}

/// A card answers one click, as in Spatial: it opens. It grows a little
/// under the pointer and gives a little while pressed, so both the hover
/// and the click show before anything opens.
private struct CardClick: ViewModifier {
    /// Shown in a small pill under the card while the pointer is on it:
    /// a note's file name, which its page does not say.
    var label: String?
    let open: () -> Void
    @State private var hovering = false

    init(label: String? = nil, open: @escaping () -> Void) {
        self.label = label
        self.open = open
    }

    func body(content: Content) -> some View {
        Button(action: open) { content }
            .buttonStyle(PressStyle(hovering: hovering))
            .onHover { hovering = $0 }
            // Hung below the card, outside its layout, so nothing moves.
            .overlay(alignment: .bottom) {
                if hovering, let label {
                    // Pushed down by its own height and a gap, so its top
                    // sits clear of the card's foot.
                    HoverLabel(text: label)
                        .offset(y: HoverLabel.height + 10)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.14), value: hovering)
            // The grown card and its label draw over their neighbors.
            .zIndex(hovering ? 1 : 0)
    }

    private struct PressStyle: ButtonStyle {
        let hovering: Bool

        func makeBody(configuration: ButtonStyleConfiguration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.985 : (hovering ? 1.027 : 1))
                .animation(.spring(duration: 0.3, bounce: 0.25), value: hovering)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .contentShape(Rectangle())
        }
    }
}

/// Names for new notes and folders: the plain name, then numbered.
enum LibraryNames {
    static func unused(_ base: String, extension ext: String, in folder: URL) -> URL {
        func url(_ name: String) -> URL {
            let url = folder.appendingPathComponent(name, isDirectory: ext.isEmpty)
            return ext.isEmpty ? url : url.appendingPathExtension(ext)
        }
        var candidate = url(base)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url("\(base) \(index)")
            index += 1
        }
        return candidate
    }
}

/// Reports a card's place in the window while it is on screen.
private struct CardFrame: ViewModifier {
    let url: URL
    @Binding var frames: [URL: CGRect]

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames[url] = $0 }
            .onDisappear { frames[url] = nil }
    }
}

/// A name shown on hover, after Spatial's hint labels: the system
/// monospace, spaced out, dark on a pale rounded tablet a shade lighter
/// than the page, with no edge. The name keeps its own case.
private struct HoverLabel: View {
    static let height: CGFloat = 24
    static let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(MenuPalette.ink)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .frame(height: Self.height)
            .background(
                Self.shape
                    .fill(MenuPalette.fill)
                    .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
            )
            .fixedSize()
            .allowsHitTesting(false)
    }
}
