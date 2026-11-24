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
        .background(LibraryPalette.background.ignoresSafeArea())
        // Spatial's style of pointer over the whole library.
        .pointerStyle(LibraryPointer.style)
        .background(keyCommands)
        .task(id: folder) {
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
                    FolderCard(folder: item)
                        .background(FolderCard.shadow)
                        .modifier(CardClick { go(to: item.url) })
                        .contextMenu { menu(for: item.url, isFolder: true) }
                        .transition(LibraryMotion.itemTransition)
                }
            }
        }
        if !listing.notes.isEmpty {
            LazyVGrid(columns: noteColumns, alignment: .leading, spacing: 18) {
                ForEach(listing.notes) { item in
                    LibraryNoteTile(note: item)
                        .modifier(CardShadow())
                        .modifier(CardClick { openNote(item.url) })
                        .contextMenu { menu(for: item.url, isFolder: false) }
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

    @ViewBuilder private func menu(for url: URL, isFolder: Bool) -> some View {
        Button("Open") { isFolder ? go(to: url) : openNote(url) }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
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

    private func openNote(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var miniature: NSImage?

    init(note: FolderListing.Note) {
        self.note = note
    }

    /// A miniature already drawn shows from the first frame.
    private var shown: NSImage? {
        miniature ?? NoteMiniature.cached(NoteMiniature.key(for: note.url, modified: note.modified, dark: colorScheme == .dark))
    }

    var body: some View {
        NoteCard(note: note, miniature: shown.map { Image(nsImage: $0) })
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

/// A card answers one click, as in Spatial: it opens. It gives a little
/// under the pointer while pressed, so the click shows before it lands.
private struct CardClick: ViewModifier {
    let open: () -> Void

    func body(content: Content) -> some View {
        Button(action: open) { content }
            .buttonStyle(PressStyle())
    }

    private struct PressStyle: ButtonStyle {
        func makeBody(configuration: ButtonStyleConfiguration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .contentShape(Rectangle())
        }
    }
}
