import SwiftUI
import UniformTypeIdentifiers

/// Where the library can go: into a folder or a note.
enum LibraryRoute: Hashable {
    case folder(URL)
    case note(URL)
}

/// The app's home: the root folder's folders and notes, and a stack to
/// walk into them. Opening a Markdown file from Files pushes its note.
struct LibraryView: View {
    @ObservedObject private var root = LibraryRoot.shared
    @ObservedObject private var store = ConfigurationStore.shared
    @State private var path: [LibraryRoute] = []
    /// Cards are the sources of the zoom into their folder or note.
    @Namespace private var cards

    var body: some View {
        NavigationStack(path: $path) {
            FolderView(folder: root.url, isRoot: true, cards: cards, open: open, home: { path.removeAll() })
                .navigationDestination(for: LibraryRoute.self) { route in
                    switch route {
                    case .folder(let url):
                        FolderView(folder: url, isRoot: false, cards: cards, open: open, home: { path.removeAll() })
                            .navigationTransition(.zoom(sourceID: url, in: cards))
                    case .note(let url):
                        NoteView(url: url)
                            .navigationTransition(.zoom(sourceID: url, in: cards))
                    }
                }
        }
        .id(root.url)
        .onOpenURL { url in
            _ = url.startAccessingSecurityScopedResource()
            path.append(.note(url))
        }
    }

    private func open(_ route: LibraryRoute) { path.append(route) }
}

/// A folder as two grids: its folders, then its notes.
struct FolderView: View {
    let folder: URL
    let isRoot: Bool
    let cards: Namespace.ID
    let open: (LibraryRoute) -> Void
    /// Back to the root folder.
    var home: () -> Void = {}
    @ObservedObject private var root = LibraryRoot.shared
    @State private var listing = FolderListing()
    @State private var choosingRoot = false
    @State private var query = ""
    /// Notes under this folder matching `query`; nil until a search ran.
    @State private var results: [FolderListing.Note]?
    /// Every note under this folder, read in the background when the folder
    /// opens and after changes, so search runs in memory as you type.
    @State private var searchIndex: FolderListing.SearchIndex?
    @Environment(\.scenePhase) private var scenePhase
    /// A renamed item keeps the identity it was shown with, so its card
    /// stays put and retitles rather than shrinking out and growing back.
    @State private var renamed: [String: URL] = [:]
    /// Notes and folders picked while selecting.
    @State private var selection: Set<URL> = []
    /// Select mode, as in Files: a hold on a card or on empty space starts
    /// it, taps then pick rather than open, the toast replaces the bottom
    /// bar, and only the check ends it, even with nothing picked.
    @State private var selecting = false
    @State private var movingSelection = false
    @State private var confirmingDelete = false
    @State private var namingFolder = false
    @State private var folderName = ""
    @State private var renaming = false
    @State private var renameText = ""
    /// The bottom capsule opens into a search field.
    @State private var searchOpen = false
    @FocusState private var searchFocused: Bool
    /// The scroll view's height, so empty space below the grid still takes
    /// the long press that makes a folder.
    @State private var viewport: CGFloat = 0

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Three columns on a phone, as many as fit at that size on wider screens.
    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 12)]
    /// Folders keep the design's proportions and type at two columns.
    private let folderColumns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12)]

    var body: some View {
        attachDialogs(page)
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if searching, results != nil {
                    searchResults
                } else {
                    contents
                }
            }
            .padding(.horizontal, 20)
            // Room between the bar's enso and the first row.
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, minHeight: viewport, alignment: .top)
            .contentShape(Rectangle())
            // A hold on empty space starts selecting with nothing picked,
            // where a folder can still be made. Cards take their own
            // touches first.
            .gesture(QuickPress {
                guard !selecting else { return }
                Haptics.press()
                withAnimation(Self.selectionSpring) { selecting = true }
            })
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 }
        .background(LibraryPalette.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // The enso stands at the top left; inside a folder it is followed
        // by the folder's name and takes you back to the root.
        .navigationBarBackButtonHidden(!isRoot)
        .background(SwipeBackEnabler())
        .toolbar {
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarLeading) { brand }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarLeading) { brand }
            }
            if selecting {
                ToolbarItem(placement: .principal) { selectionTitle }
                // The glass circle stays: it marks the check as the one
                // live control while picking.
                ToolbarItem(placement: .primaryAction) { doneButton }
            } else if #available(iOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) { composeButton }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { composeButton }
            }
        }
        // One floating capsule at the bottom, as the system's apps now do:
        // search and a new folder, or, while items are picked, what can be
        // done to them. The grid scrolls beneath it.
        .safeAreaInset(edge: .bottom) { bottomBar }
        .fileImporter(isPresented: $choosingRoot, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { root.choose(url) }
        }
        .task(id: folder) { await reload() }
        .task(id: query) { await search() }
        .refreshable { await reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
        .onAppear { Task { await reload() } }
        // A note's last save lands as the library reappears; reload after it.
        .onReceive(NotificationCenter.default.publisher(for: NoteFile.didSaveNotification)) { _ in
            Task { await reload() }
        }
    }

    private let brandInset: CGFloat = 10

    /// One floating capsule at the bottom, as the system's apps now do:
    /// search and a new folder, or, while items are picked, what can be
    /// done to them. The grid scrolls beneath it.
    private var bottomBar: some View {
        ZStack {
            if selecting {
                SelectionToast(
                    count: selection.count,
                    newFolder: { folderName = ""; namingFolder = true },
                    move: { movingSelection = true },
                    rename: renameAction,
                    delete: { confirmingDelete = true }
                )
                // As in Spatial: the bar drops out of the way, then the
                // toast rises; leaving, the toast drops first.
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity)
                        .animation(Self.selectionSpring.delay(0.12)),
                    removal: .move(edge: .bottom).combined(with: .opacity)
                        .animation(Self.selectionSpring)
                ))
            } else {
                LibraryBar(query: $query, searchOpen: $searchOpen, searchFocused: $searchFocused)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, searchOpen && !selecting ? 16 : 0)
        .animation(LibraryBar.grow, value: searchOpen)
        .padding(.bottom, 4)
    }

    /// New note, drawn in Spatial's line style and standing on the page
    /// without a glass circle, as the enso does on the left.
    private var composeButton: some View {
        Button(action: newNote) {
            ComposeGlyph()
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 22, height: 22)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Mirror of the enso's inset, so the glyph lines up with the grid.
        .offset(x: brandInset)
        .accessibilityLabel("New Note")
    }

    /// Ends picking: the system's checkmark in the bar's glass circle.
    private var doneButton: some View {
        Button("Done", systemImage: "checkmark", action: endSelecting)
            .labelStyle(.iconOnly)
    }

    /// Renaming is offered when one item is picked.
    private var renameAction: (() -> Void)? {
        guard selection.count == 1 else { return nil }
        return { beginRename() }
    }

    private func attachDialogs<Content: View>(_ content: Content) -> some View {
        content
            .sheet(isPresented: $movingSelection) {
                MoveSheet(root: root.url, current: folder, isDefaultRoot: root.isDefault, moving: selection) { destination in
                    moveSelection(to: destination)
                }
                .presentationDetents([.medium, .large])
            }
            .confirmationDialog("Delete \(selectionDescription)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: deleteSelection)
            } message: {
                Text(selectedFolders.isEmpty ? "The files are removed from the folder." : "Folders are deleted with everything in them.")
            }
            .alert("Rename", isPresented: $renaming) {
                TextField("Name", text: $renameText)
                Button("Rename", action: renameSelection)
                Button("Cancel", role: .cancel) {}
            }
            .alert("New Folder", isPresented: $namingFolder) {
                TextField("Name", text: $folderName)
                Button("Create", action: createFolder)
                Button("Cancel", role: .cancel) {}
            }
    }

    /// "3 Selected", or "Select Items" with nothing picked, as in Files.
    private var selectionTitle: some View {
        Text(selection.isEmpty ? "Select Items" : "\(selection.count) Selected")
            .font(.system(size: 16, weight: .semibold))
    }

    /// The enso, and inside a folder the folder's name after it, which takes
    /// you back to the root. At the root the enso holds the library's
    /// settings instead.
    @ViewBuilder private var brand: some View {
        if isRoot {
            Menu {
                Button("Choose Root Folder…", systemImage: "folder") { choosingRoot = true }
                if !root.isDefault {
                    Button("Use Paper's Folder", systemImage: "arrow.uturn.backward") { root.reset() }
                }
            } label: {
                brandLabel
            }
            .accessibilityLabel("Paper")
        } else {
            Button(action: home) { brandLabel }
                .accessibilityLabel("Paper, \(folder.lastPathComponent)")
        }
    }

    private var brandLabel: some View {
        Group {
            HStack(spacing: 8) {
                Image("Enso")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                if !isRoot {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LibraryPalette.secondaryLabel)
                    Text(folder.lastPathComponent)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.primary)
            // The bar insets its items more than the grid's 20 pt margin;
            // the enso lines up with the cards' left edge.
            .offset(x: -brandInset)
        }
    }

    @ViewBuilder private var searchResults: some View {
        if let results, results.isEmpty {
            Text("No notes match “\(query)”.")
                .foregroundStyle(LibraryPalette.secondaryLabel)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 80)
        } else if let results {
            noteGrid(results)
        }
    }

    private func noteGrid(_ notes: [FolderListing.Note]) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(notes.map { (identity(of: $0.url), $0) }, id: \.0) { _, item in
                NoteCard(note: item, selected: selection.contains(item.url))
                    .matchedTransitionSource(id: item.url, in: cards) { source in
                        source.clipShape(NoteCard.shape)
                    }
                    // Outside the zoom's source, whose clip would cut it off.
                    .modifier(CardShadow())
                    .modifier(PickGesture(
                        tap: { if selecting { toggle(item.url) } else { open(.note(item.url)) } },
                        pick: { changeSelection { $0.insert(item.url) } }
                    ))
                    .transition(Self.itemTransition)
            }
        }
    }

    @ViewBuilder private var contents: some View {
                if !listing.folders.isEmpty {
                    LazyVGrid(columns: folderColumns, spacing: 12) {
                        ForEach(listing.folders.map { (identity(of: $0.url), $0) }, id: \.0) { _, item in
                            FolderCard(folder: item, selected: selection.contains(item.url))
                                .matchedTransitionSource(id: item.url, in: cards)
                                .modifier(PickGesture(
                                    tap: { if selecting { toggle(item.url) } else { open(.folder(item.url)) } },
                                    pick: { changeSelection { $0.insert(item.url) } }
                                ))
                                .transition(Self.itemTransition)
                        }
                    }
                }
                if !listing.notes.isEmpty {
                    noteGrid(listing.notes)
                }
                if listing.folders.isEmpty, listing.notes.isEmpty {
                    Text("No notes here yet.")
                        .foregroundStyle(LibraryPalette.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 80)
                }
    }

    /// Cards grow in as they arrive and shrink out as they go; the rest
    /// slide to close or open the gap.
    static let itemTransition = AnyTransition.scale(scale: 0.6).combined(with: .opacity)
    static let itemSpring = Animation.spring(duration: 0.4, bounce: 0.18)

    /// What a card is known by: its first URL, carried across renames.
    private func identity(of url: URL) -> URL { renamed[url.standardizedFileURL.path] ?? url }

    /// `animated` after the library's own changes (delete, move, rename, a
    /// new folder); refreshes from elsewhere land without animation.
    private func reload(animated: Bool = false) async {
        let folder = folder
        let isDefault = isRoot && root.isDefault
        let loaded = await Task.detached { FolderListing.load(folder, isDefaultRoot: isDefault) }.value
        if animated {
            withAnimation(Self.itemSpring) { listing = loaded }
        } else {
            listing = loaded
        }
        searchIndex = await Task.detached { FolderListing.index(under: folder, isDefaultRoot: isDefault) }.value
        if searching { await search() }
    }

    /// Waits for typing to pause, then searches this folder and everything
    /// under it.
    /// Searches the in-memory index at once; until the index is built, the
    /// disk, without clearing what is shown in the meantime.
    private func search() async {
        guard searching else { results = nil; return }
        if let searchIndex {
            results = searchIndex.search(query)
            return
        }
        let folder = folder, query = query
        let isDefault = isRoot && root.isDefault
        let found = await Task.detached { FolderListing.search(query, under: folder, isDefaultRoot: isDefault) }.value
        guard !Task.isCancelled else { return }
        results = found
    }

    private func toggle(_ url: URL) {
        changeSelection { picked in
            if picked.contains(url) { picked.remove(url) } else { picked.insert(url) }
        }
    }

    static let selectionSpring = Animation.spring(duration: 0.35, bounce: 0.15)

    /// Every change to the picked notes animates, so the bottom bar slides
    /// away and back rather than vanishing.
    private func changeSelection(_ change: (inout Set<URL>) -> Void) {
        withAnimation(Self.selectionSpring) {
            change(&selection)
            if !selection.isEmpty { selecting = true }
        }
    }

    /// The check: drop what is picked and leave select mode.
    private func endSelecting() {
        withAnimation(Self.selectionSpring) {
            selection.removeAll()
            selecting = false
        }
    }

    private func moveSelection(to destination: URL) {
        for url in selection {
            try? NoteFile.move(url, into: destination)
        }
        endSelecting()
        Task { await reload(animated: true) }
    }

    private func deleteSelection() {
        for url in selection {
            try? NoteFile.delete(url)
        }
        endSelecting()
        Task { await reload(animated: true) }
    }

    private var selectedFolders: [URL] {
        listing.folders.map(\.url).filter(selection.contains)
    }

    /// "this note", "this folder", "3 notes", "2 items".
    private var selectionDescription: String {
        let folders = selectedFolders.count
        let notes = selection.count - folders
        switch (notes, folders) {
        case (1, 0): return "this note"
        case (0, 1): return "this folder"
        case (_, 0): return "\(notes) notes"
        case (0, _): return "\(folders) folders"
        default: return "\(selection.count) items"
        }
    }

    private func beginRename() {
        guard let url = selection.first else { return }
        let isFolder = selectedFolders.contains(url)
        renameText = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        renaming = true
    }

    private func renameSelection() {
        guard let url = selection.first else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, !name.hasPrefix(".") else { return }
        let isFolder = selectedFolders.contains(url)
        if let renamedTo = try? NoteFile.rename(url, to: name, isFolder: isFolder) {
            renamed[renamedTo.standardizedFileURL.path] = identity(of: url)
        }
        endSelecting()
        Task { await reload(animated: true) }
    }

    private func createFolder() {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, !name.hasPrefix(".") else { return }
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: false)
        // Making a folder finishes the task, as moving or deleting does.
        endSelecting()
        Task { await reload(animated: true) }
    }

    /// An empty `Untitled.md` (numbered when taken), opened at once.
    private func newNote() {
        var name = "Untitled.md"
        var index = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "Untitled \(index).md"
            index += 1
        }
        let url = folder.appendingPathComponent(name)
        guard (try? NoteFile.write("", to: url)) != nil else { return }
        open(.note(url))
    }
}

/// The library's colors: Marina's dark tokens, and Spatial's soft grays
/// in light.
enum LibraryPalette {
    static let background = dynamic(dark: 0x0C0D0D, light: 0xE8EAEB)
    static let card = dynamic(dark: 0x111212, light: 0xF3F4F5)
    /// The dark card's hairline; light cards have none.
    static let border = dynamic(dark: 0x1F2020, light: 0xFFFFFF)
    static let secondaryLabel = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0x959EAC) : UIColor(hex: 0x6B7280)
    })

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }
}

/// Marina's folder primitive: the layered folder shape, the item count
/// and the name at its lower left.
struct FolderCard: View {
    let folder: FolderListing.Folder
    var selected = false

    /// The artwork draws the folder inside a larger canvas (room for its
    /// shadow): the shape spans x 10.5–301.6 and y 4.5–210 of 312 × 226.
    /// The card is sized by the shape, so its edges meet the grid's like a
    /// note card's, and the artwork overhangs it by the shadow's margin.
    static let canvas = CGSize(width: 312.054, height: 226.45)
    static let shape = CGRect(x: 10.5, y: 4.5, width: 291.054, height: 205.45)

    var body: some View {
        Color.clear
            .aspectRatio(Self.shape.width / Self.shape.height, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let scale = proxy.size.width / Self.shape.width
                    Image("FolderShape")
                        .resizable()
                        .frame(width: Self.canvas.width * scale, height: Self.canvas.height * scale)
                        .modifier(CardShadow())
                        .offset(x: -Self.shape.minX * scale, y: -Self.shape.minY * scale)
                }
            }
            .overlay(alignment: .bottomLeading) {
                // The label sits 26 pt in from the shape's left and ends
                // about 26 pt above its bottom on the 291 pt design folder;
                // anchored at the bottom, it cannot run past the card.
                GeometryReader { proxy in
                    let scale = proxy.size.width / Self.shape.width
                    label
                        .frame(width: proxy.size.width * 0.78, alignment: .leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.leading, 25.2 * scale)
                        .padding(.bottom, 26 * scale)
                }
            }
            // Picked: a bright outline around the folder's silhouette.
            .overlay {
                if selected { FolderSilhouette().stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineJoin: .round)) }
            }
            .animation(.easeOut(duration: 0.15), value: selected)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var label: some View {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.itemCount == 1 ? "1 item" : "\(folder.itemCount) items")
                        .font(.system(size: 12))
                        .foregroundStyle(LibraryPalette.secondaryLabel)
                    Text(folder.name)
                        .font(.system(size: 14, weight: .medium))
                        .tracking(-0.07)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
    }
}

/// Marina's spatial note card: the note itself in miniature, drawn by
/// the editor at a phone's page width and scaled into the card, so the
/// card is the page it zooms into. Until the miniature is drawn, the card
/// shows the title.
struct NoteCard: View {
    /// One shape for the card, its border and the zoom's clip, so the clip
    /// never shaves the border at the corners.
    static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    let note: FolderListing.Note
    var selected = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var miniature: UIImage?

    var body: some View {
        NoteCard.shape
            .fill(LibraryPalette.card)
            .aspectRatio(NoteMiniature.aspect, contentMode: .fit)
            .overlay {
                if let miniature {
                    Image(uiImage: miniature)
                        .resizable()
                        .scaledToFill()
                } else {
                    Text(note.title)
                        .font(Font(Appearance.headingFont(size: 11)))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(10)
                }
            }
            .clipShape(NoteCard.shape)
            // A hairline in dark; in light, as in Spatial, the card has
            // no edge until it is picked.
            .overlay {
                if colorScheme == .dark { NoteCard.shape.strokeBorder(LibraryPalette.border, lineWidth: 1) }
            }
            // Picked, as in Spatial: a bright ring around the card.
            .overlay {
                if selected { NoteCard.shape.strokeBorder(Color.white, lineWidth: 3) }
            }
            .animation(.easeOut(duration: 0.15), value: selected)
            .contentShape(NoteCard.shape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(note.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .task(id: NoteMiniature.Key(url: note.url, modified: note.modified, dark: colorScheme == .dark)) {
                miniature = NoteMiniature.image(for: note, dark: colorScheme == .dark)
            }
    }
}

/// Miniatures of notes, drawn by an offscreen editor and kept for as long
/// as the note is unchanged.
@MainActor
enum NoteMiniature {
    /// The card's shape, a page a phone's width across.
    static let aspect: CGFloat = 3.0 / 4.0
    static let pageWidth: CGFloat = 402
    /// Only the head of a long note can show.
    static let characterLimit = 2400
    /// A little more room than the phone's page, so the miniature breathes.
    static let margins = UIEdgeInsets(top: 48, left: 30, bottom: 48, right: 30)

    struct Key: Hashable {
        let url: URL
        let modified: Date
        let dark: Bool
    }

    private static var cache: [Key: UIImage] = [:]

    static func image(for note: FolderListing.Note, dark: Bool) -> UIImage? {
        let key = Key(url: note.url, modified: note.modified, dark: dark)
        if let cached = cache[key] { return cached }
        guard let text = try? NoteFile.read(note.url) else { return nil }
        let head = String(text.prefix(characterLimit))
        let size = CGSize(width: pageWidth, height: pageWidth / aspect)
        let editor = MobileTextView()
        editor.overrideUserInterfaceStyle = dark ? .dark : .light
        editor.frame = CGRect(origin: .zero, size: size)
        editor.pageMargins = margins
        editor.documentURL = note.url
        editor.load(head)
        // The miniature keeps the card's color; the page opens onto the
        // darker library background.
        editor.backgroundColor = UIColor(LibraryPalette.card)
        editor.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            editor.layer.render(in: context.cgContext)
        }
        cache[key] = image
        return image
    }
}

/// The toast while selecting, after Spatial's: a dark capsule with a new
/// folder always, and, once something is picked, a folder to move it, a
/// pencil to rename it (one item only) and a bin to delete it.
private struct SelectionToast: View {
    /// Spatial's corners: rounded, not a full capsule.
    static let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
    let count: Int
    let newFolder: () -> Void
    let move: () -> Void
    /// Offered when one item is picked.
    let rename: (() -> Void)?
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: newFolder) {
                FolderPlusGlyph()
                    .frame(width: 56, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New Folder")
            if count > 0 {
                button(FolderGlyph(), label: "Move", action: move)
                if let rename { button(PencilGlyph(), label: "Rename", action: rename) }
                button(TrashGlyph(), label: "Delete", action: delete)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            // The shadow falls from the capsule alone, not from the glyphs.
            Self.shape
                .fill(ToastPalette.fill)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        }
        .overlay(Self.shape.strokeBorder(ToastPalette.border, lineWidth: 1))
    }

    private func button(_ glyph: some Shape, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { BarGlyph(glyph: glyph) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }
}

enum ToastPalette {
    static let fill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x212426) : UIColor(hex: 0xF1F1F0) })
    static let border = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x2E3133) : UIColor(hex: 0xDEDEDC) })
    static let glyph = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xB9BEC4) : UIColor(hex: 0x4B5057) })
}

/// Picks where to move notes: the root and every folder under it.
private struct MoveSheet: View {
    let root: URL
    let current: URL
    let isDefaultRoot: Bool
    /// What is being moved: a folder cannot go into itself or below itself.
    var moving: Set<URL> = []
    let choose: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [URL] = []
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List(folders, id: \.self) { folder in
                Button {
                    choose(folder)
                    dismiss()
                } label: {
                    Label(name(of: folder), systemImage: "folder")
                }
                .disabled(!canMove(into: folder))
            }
            .navigationTitle("Move to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Folder", systemImage: "folder.badge.plus") { name = ""; naming = true }
                }
            }
            // A new folder is made beside the notes, in the folder being
            // viewed, and the notes go straight into it.
            .alert("New Folder", isPresented: $naming) {
                TextField("Name", text: $name)
                Button("Create and Move", action: createAndMove)
                Button("Cancel", role: .cancel) {}
            }
        }
        .task {
            let root = root, isDefault = isDefaultRoot
            folders = await Task.detached { [root] + FolderListing.allFolders(under: root, isDefaultRoot: isDefault) }.value
        }
    }

    private func canMove(into folder: URL) -> Bool {
        let target = folder.standardizedFileURL.path
        if target == current.standardizedFileURL.path { return false }
        return !moving.contains { item in
            let path = item.standardizedFileURL.path
            return target == path || target.hasPrefix(path + "/")
        }
    }

    private func createAndMove() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !trimmed.isEmpty, !trimmed.hasPrefix(".") else { return }
        let folder = current.appendingPathComponent(trimmed, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil
            || FileManager.default.fileExists(atPath: folder.path)
        else { return }
        choose(folder)
        dismiss()
    }

    /// The path below the root, `Paper` for the root itself.
    private func name(of folder: URL) -> String {
        let base = root.standardizedFileURL.path
        let path = folder.standardizedFileURL.path
        guard path.count > base.count else { return isDefaultRoot ? "Paper" : root.lastPathComponent }
        return String(path.dropFirst(base.count + 1)).replacingOccurrences(of: "/", with: " › ")
    }
}

enum Haptics {
    @MainActor static func press() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

/// Hiding the back button also stops the edge swipe back; this lets the
/// swipe go on working on screens that hide it.
private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
            navigationController?.interactivePopGestureRecognizer?.delegate = nil
        }
    }
}

/// The folder artwork's outline (its back panel and tab), fitted to the
/// card, which is the shape's own box, for the picked state's ring.
struct FolderSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        // Artwork coordinates, measured from the shape's own top left.
        let box = FolderCard.shape
        let sx = rect.width / box.width, sy = rect.height / box.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - box.minX) * sx, y: rect.minY + (y - box.minY) * sy)
        }
        var path = Path()
        path.move(to: p(10.5, 22.844))
        path.addCurve(to: p(28.844, 4.5), control1: p(10.5, 10.615), control2: p(16.615, 4.5))
        path.addLine(to: p(104.665, 4.5))
        path.addCurve(to: p(121.785, 11.837), control1: p(111.187, 4.5), control2: p(116.894, 6.946))
        path.addLine(to: p(136.46, 26.512))
        path.addCurve(to: p(151.135, 31.404), control1: p(139.722, 29.774), control2: p(144.613, 31.404))
        path.addLine(to: p(283.21, 31.404))
        path.addCurve(to: p(301.554, 49.748), control1: p(295.44, 31.404), control2: p(301.554, 37.519))
        path.addLine(to: p(301.554, 191.606))
        path.addCurve(to: p(283.21, 209.95), control1: p(301.554, 203.835), control2: p(295.44, 209.95))
        path.addLine(to: p(28.844, 209.95))
        path.addCurve(to: p(10.5, 191.606), control1: p(16.615, 209.95), control2: p(10.5, 203.835))
        path.closeSubpath()
        return path
    }
}

/// A glyph in a toast: one size, weight and color for every button.
private struct BarGlyph<Glyph: Shape>: View {
    let glyph: Glyph

    /// Two points on the 24 pt grid, drawn at 22 pt.
    static var style: StrokeStyle { StrokeStyle(lineWidth: 2 * 22 / 24, lineCap: .round, lineJoin: .round) }

    var body: some View {
        glyph
            .stroke(ToastPalette.glyph, style: Self.style)
            .frame(width: 22, height: 22)
            .frame(width: 56, height: 44)
            .contentShape(Rectangle())
    }
}

/// The library's search, in the system's glass: a small "Search" pill at
/// the bottom, as on the Home Screen, that grows into a field across the
/// screen as the keyboard rises; closing it clears the search. It is one
/// glass shape throughout, so opening stretches it rather than swapping it.
private struct LibraryBar: View {
    @Binding var query: String
    @Binding var searchOpen: Bool
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: searchOpen ? 6 : 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: searchOpen ? 17 : 13, weight: .medium))
                // Closed, the pill is quiet, as the Home Screen's is: gray
                // glyph and word, not the primary color.
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                // The pill's word and the field's placeholder sit in the
                // same place, so the word stays put as the pill grows.
                if searchOpen {
                    TextField("Search", text: $query)
                        .focused(searchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .font(.system(size: 17))
                        .transition(.opacity)
                } else {
                    Text("Search")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: searchOpen ? .infinity : nil, alignment: .leading)
            if searchOpen {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Search")
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        // Closed, the Home Screen's size: about 30 pt tall.
        .padding(.leading, searchOpen ? 16 : 12)
        .padding(.trailing, searchOpen ? 4 : 13)
        .frame(height: searchOpen ? 48 : 30)
        .contentShape(Capsule())
        .onTapGesture { if !searchOpen { open() } }
        .modifier(GlassCapsule())
        .accessibilityElement(children: searchOpen ? .contain : .combine)
        .accessibilityAddTraits(searchOpen ? [] : .isButton)
    }

    /// The same spring as the keyboard's rise, so the pill grows with it.
    static let grow = Animation.spring(duration: 0.4, bounce: 0.12)

    private func open() {
        withAnimation(Self.grow) { searchOpen = true }
        searchFocused.wrappedValue = true
    }

    private func close() {
        searchFocused.wrappedValue = false
        withAnimation(Self.grow) {
            query = ""
            searchOpen = false
        }
    }
}

/// The folder glyph at full size with a plus badge in the clear space
/// above its top right corner, as the system's folder-plus has: the
/// badge's ring is cut out of the corner so the two never touch.
private struct FolderPlusGlyph: View {
    /// Badge centre and the clear ring around it, on the 24 pt grid.
    private static let badge = CGPoint(x: 20.5, y: 3.5)
    private static let clearance: CGFloat = 4.2
    private static let arm: CGFloat = 2.4

    var body: some View {
        FolderGlyph()
            .stroke(.foreground, style: BarGlyph<FolderGlyph>.style)
            .frame(width: 22, height: 22)
            .mask {
                Canvas { context, size in
                    let s = size.width / 24
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                    context.blendMode = .destinationOut
                    let r = Self.clearance * s
                    context.fill(Path(ellipseIn: CGRect(
                        x: Self.badge.x * s - r, y: Self.badge.y * s - r, width: r * 2, height: r * 2
                    )), with: .color(.black))
                }
            }
            .overlay {
                Canvas { context, size in
                    let s = size.width / 24
                    let c = CGPoint(x: Self.badge.x * s, y: Self.badge.y * s)
                    var plus = Path()
                    plus.move(to: CGPoint(x: c.x, y: c.y - Self.arm * s))
                    plus.addLine(to: CGPoint(x: c.x, y: c.y + Self.arm * s))
                    plus.move(to: CGPoint(x: c.x - Self.arm * s, y: c.y))
                    plus.addLine(to: CGPoint(x: c.x + Self.arm * s, y: c.y))
                    context.stroke(plus, with: .foreground, style: StrokeStyle(lineWidth: 2 * s, lineCap: .round))
                }
                .frame(width: 22, height: 22)
            }
            .foregroundStyle(ToastPalette.glyph)
    }
}

/// Liquid Glass on iOS 26; a material capsule before it.
private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

/// Spatial-style compose glyph on a 24 pt grid: a rounded page open at its
/// top right corner, and a pen stroke running into it.
struct ComposeGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        // The page: from the top edge round the left, bottom and right.
        path.move(to: p(11, 4))
        path.addLine(to: p(8, 4))
        path.addQuadCurve(to: p(4, 8), control: p(4, 4))
        path.addLine(to: p(4, 16))
        path.addQuadCurve(to: p(8, 20), control: p(4, 20))
        path.addLine(to: p(16, 20))
        path.addQuadCurve(to: p(20, 16), control: p(20, 20))
        path.addLine(to: p(20, 13))
        // The pen: a stroke from the top right into the page.
        path.move(to: p(19.5, 4.5))
        path.addLine(to: p(11, 13))
        return path
    }
}

/// A card's touch: a tap opens it (or picks it while selecting), and a
/// short hold picks it. The card gives under the finger at once, so the
/// hold shows it has registered before it completes.
private struct PickGesture: ViewModifier {
    let tap: () -> Void
    let pick: () -> Void
    @State private var pressing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressing ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: pressing)
            .gesture(QuickPress(onPressing: { pressing = $0 }, onTap: tap) {
                Haptics.press()
                pick()
            })
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, tap)
            .accessibilityAction(named: "Select", pick)
    }
}

/// A hold that counts from the moment the finger lands. SwiftUI's long
/// press inside a scroll view only hears the touch once the scroll view
/// has held it back (about 0.15 s), so its holds run long; a UIKit
/// recognizer sees the touch at once. It also reports the press as it
/// starts and ends, and a tap when the finger lifts before the hold.
private struct QuickPress: UIGestureRecognizerRepresentable {
    static let duration: TimeInterval = 0.35
    var onPressing: (Bool) -> Void = { _ in }
    var onTap: (() -> Void)?
    let onHold: () -> Void

    func makeUIGestureRecognizer(context: Context) -> Recognizer {
        let recognizer = Recognizer()
        recognizer.minimumPressDuration = Self.duration
        recognizer.allowableMovement = 10
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: Recognizer, context: Context) {
        recognizer.onPressing = onPressing
        recognizer.onTap = onTap
    }

    func handleUIGestureRecognizerAction(_ recognizer: Recognizer, context: Context) {
        if recognizer.state == .began { onHold() }
    }

    final class Recognizer: UILongPressGestureRecognizer {
        var onPressing: (Bool) -> Void = { _ in }
        var onTap: (() -> Void)?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
            if state == .possible { onPressing(true) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            // Lifted before the hold, without wandering off: a tap.
            let early = state == .possible
            super.touchesEnded(touches, with: event)
            if early { onTap?() }
        }

        override func reset() {
            super.reset()
            onPressing(false)
        }
    }
}

/// A pencil on the toast glyphs' 24 pt grid: a slanted body with a
/// rounded tip at the lower left and a band below its end.
struct PencilGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        // As tall as the folder and the bin: about 4–20 on the grid.
        path.move(to: p(15.9, 4.2))
        path.addLine(to: p(19.8, 8.1))
        path.addLine(to: p(8.75, 19.15))
        path.addLine(to: p(3.6, 20.4))
        path.addLine(to: p(4.85, 15.25))
        path.closeSubpath()
        path.move(to: p(13.3, 6.8))
        path.addLine(to: p(17.2, 10.7))
        return path
    }
}

/// A folder on the toast glyphs' 24 pt grid: a rounded body whose tab
/// steps down at the top left.
struct FolderGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(3, 8))
        path.addQuadCurve(to: p(6, 5), control: p(3, 5))
        path.addLine(to: p(9, 5))
        path.addQuadCurve(to: p(10.9, 5.8), control: p(10.2, 5))
        path.addLine(to: p(12.1, 7))
        path.addQuadCurve(to: p(14, 7.8), control: p(12.8, 7.8))
        path.addLine(to: p(18, 7.8))
        path.addQuadCurve(to: p(21, 10.8), control: p(21, 7.8))
        path.addLine(to: p(21, 16))
        path.addQuadCurve(to: p(18, 19), control: p(21, 19))
        path.addLine(to: p(6, 19))
        path.addQuadCurve(to: p(3, 16), control: p(3, 19))
        path.closeSubpath()
        return path
    }
}

/// A bin on the toast glyphs' 24 pt grid: a lid with a flat handle over a
/// tapered body.
struct TrashGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        // The lid and its handle.
        path.move(to: p(3.5, 6.5))
        path.addLine(to: p(20.5, 6.5))
        path.move(to: p(9, 6.5))
        path.addLine(to: p(9, 5))
        path.addQuadCurve(to: p(10.5, 3.5), control: p(9, 3.5))
        path.addLine(to: p(13.5, 3.5))
        path.addQuadCurve(to: p(15, 5), control: p(15, 3.5))
        path.addLine(to: p(15, 6.5))
        // The body, narrowing to a rounded foot.
        path.move(to: p(5.5, 6.5))
        path.addLine(to: p(6.7, 18))
        path.addQuadCurve(to: p(8.9, 20), control: p(6.9, 20))
        path.addLine(to: p(15.1, 20))
        path.addQuadCurve(to: p(17.3, 18), control: p(17.1, 20))
        path.addLine(to: p(18.5, 6.5))
        return path
    }
}

/// A card's shadow. In light, as in Spatial, two: a tight contact shadow
/// that draws the edge, under a soft fall-off. In dark, one deeper soft
/// shadow, where a light one would not show.
struct CardShadow: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if colorScheme == .dark {
            content.shadow(color: .black.opacity(0.45), radius: 8, y: 4)
        } else {
            content
                .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
                .shadow(color: .black.opacity(0.07), radius: 10, y: 5)
        }
    }
}
