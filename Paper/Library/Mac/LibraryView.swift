import AppKit
import SwiftUI

/// A folder opened in Paper, as the iPhone library shows one: its folders as
/// folder cards, then its notes as miniatures of the page, newest first, in
/// a grid that scrolls down and never pans. Clicking picks a card; a double
/// click walks into a folder or opens a note in its own window. The
/// breadcrumb at the top walks back out, as far as the folder opened.
struct LibraryView: View {
    /// The folder opened: the library goes no higher.
    let root: URL
    /// The folder shown, the root or one under it.
    @State private var folder: URL
    /// Folders walked out of, for ⌘[.
    @State private var history: [URL] = []
    @State private var listing = FolderListing()
    @State private var loaded = false
    @State private var selection: Set<URL> = []
    @State private var watcher: FolderWatcher?
    /// False only for an offscreen snapshot, which cannot draw a scroll view.
    private let scrolls: Bool

    /// `listing`, when given, is shown at once instead of loading first.
    init(root: URL, listing: FolderListing? = nil, scrolls: Bool = true) {
        self.root = root
        self.scrolls = scrolls
        _folder = State(initialValue: root.standardizedFileURL)
        if let listing {
            _listing = State(initialValue: listing)
            _loaded = State(initialValue: true)
        }
    }

    private let folderColumns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 18)]
    private let noteColumns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 18)]

    var body: some View {
        VStack(spacing: 0) {
            LibraryBreadcrumb(root: root, folder: folder, go: { go(to: $0) })
                .frame(height: 52)
            Group {
                if scrolls {
                    ScrollView { page }
                } else {
                    page.frame(maxHeight: .infinity, alignment: .top)
                }
            }
            // A click on empty space drops what is picked, as in Finder.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selection.removeAll() }
            }
        }
        .background(LibraryPalette.background.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
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
                    FolderCard(folder: item, selected: selection.contains(item.url))
                        .background(FolderCard.shadow)
                        .modifier(CardClicks(
                            select: { pick(item.url) },
                            open: { go(to: item.url) }
                        ))
                        .contextMenu { menu(for: item.url, isFolder: true) }
                        .transition(LibraryMotion.itemTransition)
                }
            }
        }
        if !listing.notes.isEmpty {
            LazyVGrid(columns: noteColumns, alignment: .leading, spacing: 18) {
                ForEach(listing.notes) { item in
                    LibraryNoteTile(note: item, selected: selection.contains(item.url))
                        .modifier(CardShadow())
                        .modifier(CardClicks(
                            select: { pick(item.url) },
                            open: { openNote(item.url) }
                        ))
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

    /// ⌘↑ to the enclosing folder and ⌘[ back, as in Finder; Escape drops
    /// the picked cards. The buttons are hidden; only their keys act.
    private var keyCommands: some View {
        ZStack {
            Button("Enclosing Folder") { goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Back") { goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Open Selection") { openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Deselect") { selection.removeAll() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Navigation

    private func go(to target: URL) {
        let target = target.standardizedFileURL
        guard target != folder else { return }
        history.append(folder)
        selection.removeAll()
        folder = target
    }

    private func goUp() {
        guard folder != root.standardizedFileURL else { return }
        go(to: folder.deletingLastPathComponent())
    }

    private func goBack() {
        guard let previous = history.popLast() else { return }
        selection.removeAll()
        folder = previous
    }

    private func openNote(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }

    private func openSelection() {
        let folders = Set(listing.folders.map(\.url))
        for url in selection {
            if folders.contains(url) {
                go(to: url)
                return
            }
            openNote(url)
        }
    }

    /// A plain click picks one card; ⌘-click adds or removes it.
    private func pick(_ url: URL) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
        } else {
            selection = [url]
        }
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
        selection.formIntersection(fresh.folders.map(\.url) + fresh.notes.map(\.url))
    }

    private func watch() {
        watcher?.cancel()
        watcher = FolderWatcher(folder: folder) {
            Task { await reload() }
        }
    }
}

/// The path from the folder opened down to the one shown, after the enso,
/// beside the window's buttons. Each step walks back up to it.
private struct LibraryBreadcrumb: View {
    let root: URL
    let folder: URL
    let go: (URL) -> Void

    /// The root, then each folder below it down to the one shown.
    private var steps: [URL] {
        let root = root.standardizedFileURL
        var steps = [root]
        let below = folder.standardizedFileURL.pathComponents.dropFirst(root.pathComponents.count)
        var url = root
        for component in below {
            url = url.appendingPathComponent(component, isDirectory: true)
            steps.append(url)
        }
        return steps
    }

    var body: some View {
        HStack(spacing: 8) {
            Image("Enso")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LibraryPalette.secondaryLabel)
                }
                if index == steps.count - 1 {
                    Text(step.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else {
                    Button(step.lastPathComponent) { go(step) }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LibraryPalette.secondaryLabel)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        // Clear of the window's buttons, which sit in the same band.
        .padding(.leading, 92)
        .padding(.trailing, 24)
        .padding(.top, 6)
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

/// Finder's clicks on a card: one picks it at once, two open it. The single
/// click is not held back waiting to see whether a second follows.
private struct CardClicks: ViewModifier {
    let select: () -> Void
    let open: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: open)
            .simultaneousGesture(TapGesture().onEnded(select))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, open)
    }
}
