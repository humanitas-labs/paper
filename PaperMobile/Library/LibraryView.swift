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
    @Environment(\.scenePhase) private var scenePhase
    /// Notes picked with a long press; while any are picked, taps pick
    /// rather than open and the toast replaces the bottom bar.
    @State private var selection: Set<URL> = []
    @State private var movingSelection = false
    @State private var confirmingDelete = false
    @State private var namingFolder = false
    @State private var folderName = ""
    /// The scroll view's height, so empty space below the grid still takes
    /// the long press that makes a folder.
    @State private var viewport: CGFloat = 0

    private var selecting: Bool { !selection.isEmpty }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Three columns on a phone, as many as fit at that size on wider screens.
    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if searching {
                    searchResults
                } else {
                    contents
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, minHeight: viewport, alignment: .top)
            .contentShape(Rectangle())
            // A hold on empty space makes a folder; cards take their own.
            .onLongPressGesture(minimumDuration: 0.5) {
                guard !selecting else { return }
                Haptics.press()
                folderName = ""
                namingFolder = true
            }
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
            if selecting {
                ToolbarItem(placement: .principal) { selectionTitle }
                ToolbarItem(placement: .primaryAction) {
                    Button("Done", systemImage: "checkmark") { selection.removeAll() }
                        .labelStyle(.iconOnly)
                }
            } else {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarLeading) { brand }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) { brand }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Note", systemImage: "square.and.pencil", action: newNote)
                }
            }
        }
        .modifier(BottomSearch(query: $query, hidden: selecting))
        .overlay(alignment: .bottom) {
            if selecting {
                SelectionToast(count: selection.count, move: { movingSelection = true }, delete: { confirmingDelete = true })
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: selecting)
        .sheet(isPresented: $movingSelection) {
            MoveSheet(root: root.url, current: folder, isDefaultRoot: root.isDefault) { destination in
                moveSelection(to: destination)
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            selection.count == 1 ? "Delete this note?" : "Delete \(selection.count) notes?",
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: deleteSelection)
        } message: {
            Text("The files are removed from the folder.")
        }
        .alert("New Folder", isPresented: $namingFolder) {
            TextField("Name", text: $folderName)
            Button("Create", action: createFolder)
            Button("Cancel", role: .cancel) {}
        }
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
            Task { await reload(); if searching { await search() } }
        }
    }

    private let brandInset: CGFloat = 10

    /// "3 Selected", and what the folder holds beneath it, as in Notes.
    private var selectionTitle: some View {
        VStack(spacing: 1) {
            Text("\(selection.count) Selected")
                .font(.system(size: 16, weight: .semibold))
            Text(contentsSummary)
                .font(.system(size: 13))
                .foregroundStyle(LibraryPalette.secondaryLabel)
        }
    }

    private var contentsSummary: String {
        let notes = (searching ? results?.count : nil) ?? listing.notes.count
        var parts = [notes == 1 ? "1 Note" : "\(notes) Notes"]
        if !searching, !listing.folders.isEmpty {
            parts.append(listing.folders.count == 1 ? "1 Folder" : "\(listing.folders.count) Folders")
        }
        return parts.joined(separator: " · ")
    }

    /// The enso, and inside a folder the folder's name after it, which takes
    /// you back to the root. At the root the enso holds the library's
    /// settings instead.
    @ViewBuilder private var brand: some View {
        if isRoot {
            Menu {
                Button("New Folder", systemImage: "folder.badge.plus") { folderName = ""; namingFolder = true }
                Divider()
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
            ForEach(notes) { item in
                NoteCard(note: item, selected: selection.contains(item.url))
                    .matchedTransitionSource(id: item.url, in: cards) { source in
                        source.clipShape(NoteCard.shape)
                    }
                    // A tap opens, or picks while picking; a hold starts picking.
                    .onTapGesture {
                        if selecting { toggle(item.url) } else { open(.note(item.url)) }
                    }
                    .onLongPressGesture(minimumDuration: 0.4) {
                        Haptics.press()
                        selection.insert(item.url)
                    }
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    @ViewBuilder private var contents: some View {
                if !listing.folders.isEmpty {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(listing.folders) { item in
                            NavigationLink(value: LibraryRoute.folder(item.url)) {
                                FolderCard(folder: item).matchedTransitionSource(id: item.url, in: cards)
                            }
                                .buttonStyle(.plain)
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

    private func reload() async {
        let folder = folder
        let isDefault = isRoot && root.isDefault
        listing = await Task.detached { FolderListing.load(folder, isDefaultRoot: isDefault) }.value
    }

    /// Waits for typing to pause, then searches this folder and everything
    /// under it.
    private func search() async {
        guard searching else { results = nil; return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let folder = folder, query = query
        let isDefault = isRoot && root.isDefault
        let found = await Task.detached { FolderListing.search(query, under: folder, isDefaultRoot: isDefault) }.value
        guard !Task.isCancelled else { return }
        results = found
    }

    private func toggle(_ url: URL) {
        if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
    }

    private func moveSelection(to destination: URL) {
        for url in selection {
            try? NoteFile.move(url, into: destination)
        }
        selection.removeAll()
        Task { await reload(); if searching { await search() } }
    }

    private func deleteSelection() {
        for url in selection {
            try? NoteFile.delete(url)
        }
        selection.removeAll()
        Task { await reload(); if searching { await search() } }
    }

    private func createFolder() {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, !name.hasPrefix(".") else { return }
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: false)
        Task { await reload() }
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

/// The library's colors: Marina's dark tokens, with quiet light
/// counterparts so the grid follows the page's theme.
enum LibraryPalette {
    static let background = dynamic(dark: 0x0C0D0D, light: 0xFBFBFA)
    static let card = dynamic(dark: 0x111212, light: 0xF4F4F3)
    static let border = dynamic(dark: 0x1F2020, light: 0xE2E2E0)
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

    var body: some View {
        Image("FolderShape")
            .resizable()
            .aspectRatio(312.054 / 226.45, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                // The label sits 26 pt in and 147 pt down on the 293.5 pt
                // card, which the artwork draws 9.3 pt into its 312 pt
                // canvas; as fractions so it scales with the column.
                GeometryReader { proxy in
                    label
                        .frame(width: proxy.size.width * 0.78, alignment: .leading)
                        .offset(x: proxy.size.width * 35.7 / 312.054, y: proxy.size.height * 150.2 / 226.45)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }

    private var label: some View {
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.itemCount == 1 ? "1 item" : "\(folder.itemCount) items")
                        .font(.system(size: 10))
                        .foregroundStyle(LibraryPalette.secondaryLabel)
                    Text(folder.name)
                        .font(.system(size: 12, weight: .medium))
                        .tracking(-0.06)
                        .foregroundStyle(.white)
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
            .overlay(NoteCard.shape.strokeBorder(LibraryPalette.border, lineWidth: 1.5))
            // Picked, as in Spatial: a bright ring around the card.
            .overlay {
                if selected { NoteCard.shape.strokeBorder(Color.primary, lineWidth: 3) }
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

/// Search at the bottom of the screen, as in Notes, on iOS 26; at the top
/// on earlier systems. New notes are made from the top right.
private struct BottomSearch: ViewModifier {
    @Binding var query: String
    /// While picking notes, the toast takes the bottom of the screen.
    var hidden = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .searchable(text: $query, prompt: "Search")
                .toolbar {
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                }
                .toolbar(hidden ? .hidden : .automatic, for: .bottomBar)
        } else {
            content.searchable(text: $query, prompt: "Search")
        }
    }
}

/// The toast while notes are picked, after Spatial's: a dark capsule with
/// a folder to move them and a bin to delete them.
/// The two glyphs are Spatial's own, copied for this demo build only; they
/// are placeholders to replace before Paper is distributed.
private struct SelectionToast: View {
    /// Spatial's corners: rounded, not a full capsule.
    static let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    let count: Int
    let move: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            button("SpatialFolder", label: "Move \(count == 1 ? "Note" : "\(count) Notes")", action: move)
            button("SpatialTrash", label: "Delete \(count == 1 ? "Note" : "\(count) Notes")", action: delete)
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

    private func button(_ image: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(ToastPalette.glyph)
                .frame(width: 56, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private enum ToastPalette {
    static let fill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x212426) : UIColor(hex: 0xF1F1F0) })
    static let border = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x2E3133) : UIColor(hex: 0xDEDEDC) })
    static let glyph = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xB9BEC4) : UIColor(hex: 0x4B5057) })
}

/// Picks where to move notes: the root and every folder under it.
private struct MoveSheet: View {
    let root: URL
    let current: URL
    let isDefaultRoot: Bool
    let choose: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [URL] = []

    var body: some View {
        NavigationStack {
            List(folders, id: \.self) { folder in
                Button {
                    choose(folder)
                    dismiss()
                } label: {
                    Label(name(of: folder), systemImage: "folder")
                }
                .disabled(folder.standardizedFileURL == current.standardizedFileURL)
            }
            .navigationTitle("Move to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task {
            let root = root, isDefault = isDefaultRoot
            folders = await Task.detached { [root] + FolderListing.allFolders(under: root, isDefaultRoot: isDefault) }.value
        }
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
