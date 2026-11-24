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
            FolderView(folder: root.url, isRoot: true, cards: cards, open: open)
                .navigationDestination(for: LibraryRoute.self) { route in
                    switch route {
                    case .folder(let url):
                        FolderView(folder: url, isRoot: false, cards: cards, open: open)
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
    @ObservedObject private var root = LibraryRoot.shared
    @State private var listing = FolderListing()
    @State private var choosingRoot = false
    @Environment(\.scenePhase) private var scenePhase

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !listing.folders.isEmpty {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(listing.folders) { item in
                            NavigationLink(value: LibraryRoute.folder(item.url)) {
                                FolderCard(folder: item).matchedTransitionSource(id: item.url, in: cards)
                            }
                                .buttonStyle(.plain)
                        }
                    }
                }
                if !listing.notes.isEmpty {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(listing.notes) { item in
                            NavigationLink(value: LibraryRoute.note(item.url)) {
                                NoteCard(note: item).matchedTransitionSource(id: item.url, in: cards) { source in
                                    source.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                }
                            }
                                .buttonStyle(.plain)
                        }
                    }
                }
                if listing.folders.isEmpty, listing.notes.isEmpty {
                    Text("No notes here yet.")
                        .foregroundStyle(LibraryPalette.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 80)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(LibraryPalette.background.ignoresSafeArea())
        // The root has no title; a folder is named in the bar.
        .navigationTitle(isRoot ? "" : folder.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Note", systemImage: "square.and.pencil", action: newNote)
                    if isRoot {
                        Divider()
                        Button("Choose Root Folder…", systemImage: "folder") { choosingRoot = true }
                        if !root.isDefault {
                            Button("Use Paper's Folder", systemImage: "arrow.uturn.backward") { root.reset() }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .fileImporter(isPresented: $choosingRoot, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { root.choose(url) }
        }
        .task(id: folder) { await reload() }
        .refreshable { await reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
        .onAppear { Task { await reload() } }
    }

    private func reload() async {
        let folder = folder
        let isDefault = isRoot && root.isDefault
        listing = await Task.detached { FolderListing.load(folder, isDefaultRoot: isDefault) }.value
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.itemCount == 1 ? "1 item" : "\(folder.itemCount) items")
                        .font(.system(size: 12))
                        .foregroundStyle(LibraryPalette.secondaryLabel)
                    Text(folder.name)
                        .font(.system(size: 14, weight: .medium))
                        .tracking(-0.07)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
    }
}

/// Marina's spatial note card: a quiet panel with the note's title.
struct NoteCard: View {
    let note: FolderListing.Note

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(LibraryPalette.card)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(LibraryPalette.border, lineWidth: 1))
            .aspectRatio(150.0 / 200.0, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                // The page's own heading face, so the title reads as the
                // note it grows into.
                Text(note.title)
                    .font(Font(Appearance.headingFont(size: 15)))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .padding(.horizontal, 15)
                    .padding(.top, 17)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
    }
}
