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
    /// Where the cards are, for clicks and the rubber band to find them.
    /// Kept out of the view's state: the frames change on every frame of
    /// a scroll, and nothing is drawn from them.
    @State private var cards = CardFrames()
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
    /// The library's width, to keep the band off the scroller.
    @State private var width: CGFloat = 0
    /// Shown when the library shows hidden items: the ones Finder hides.
    @State private var hiddenItems: Set<URL> = []
    @State private var themeGeneration = 0
    /// The card the rename sheet is for.
    @State private var renameTarget: URL?
    /// The folder the listing is of; until the new folder's arrives, the
    /// last folder's cards are not drawn under the new name.
    @State private var listedFolder: URL?
    @AppStorage(FolderListing.showsHiddenKey) private var showsHidden = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered: HoverTarget?
    @State private var renaming = false
    @State private var renameText = ""
    /// The folder card a drag is held over.
    @State private var dropTarget: URL?
    /// The tab a carried card is held over.
    @State private var dropTab: UUID?
    /// What the drag in progress does, decided as it begins.
    @State private var dragMode: DragMode?
    private enum DragMode { case marquee, cards, ignored }
    /// The cards lifted out of the grid and following the pointer.
    @State private var carried: CarriedCards?
    /// Cards leaving or rejoining the grid by the drag: they fly, and do
    /// not shrink or grow as a deleted or new card does.
    @State private var inFlight: Set<URL> = []
    @Namespace private var liftSpace
    /// How the notes are grouped and sorted, in every library window.
    @AppStorage(LibraryGrouping.storageKey) private var groupingStorage = "none"
    @AppStorage(LibrarySort.storageKey) private var sortStorage = LibrarySort.modified.rawValue
    /// No search for now; its control is put away.
    private let query = ""
    /// Each note's frontmatter, read after the listing, for grouping.
    @State private var properties: [URL: [String: String]] = [:]
    /// When each note's file was made, read only once the grouping or
    /// the sort goes by it.
    @State private var created: [URL: Date] = [:]
    /// Paper's pins: the pinned notes of the folder shown lead the page.
    @ObservedObject private var pinStore: PinStore
    /// False only for an offscreen snapshot, which cannot draw a scroll view.
    private let scrolls: Bool

    private var folder: URL { navigation.folder }

    /// `listing`, when given, is shown at once instead of loading first.
    init(navigation: LibraryNavigation, listing: FolderListing? = nil, scrolls: Bool = true, pinStore: PinStore = .shared) {
        self.navigation = navigation
        self.scrolls = scrolls
        self.pinStore = pinStore
        if let listing {
            _listing = State(initialValue: listing)
            _loaded = State(initialValue: true)
        }
    }

    private let folderColumns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 18)]
    private let noteColumns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 18)]

    var body: some View {
        observing(library)
    }

    private var library: some View {
        VStack(spacing: 0) {
            Group {
                if scrolls {
                    ScrollView { page }
                        // Each folder opens at its top, on a fresh grid.
                        .id(folder)
                        // In full screen the system's toolbar is put
                        // away; the same header is drawn on the page.
                        .safeAreaInset(edge: .top, spacing: 0) {
                            if navigation.fullScreen { LibraryHeader(navigation: navigation) }
                        }
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
        // Files dropped on the page from elsewhere move into the folder
        // shown; a folder card takes a drop on it for itself.
        .dropDestination(for: URL.self) { dropped, _ in
            LibraryDrag.shared.drop(dropped, into: folder) { self.dropped() }
        }
        // The folder's name, after the arrows: the toolbar's in a window,
        // the drawn header's in full screen.
        .overlay(alignment: .topLeading) {
            LibraryFolderTitle(folder: folder)
                .frame(height: 52)
                .padding(.leading, navigation.fullScreen ? 94 : 181)
                .ignoresSafeArea()
        }
        // Across from the folder's name: how many are picked, the
        // grouping and the sort.
        .overlay(alignment: .topTrailing) {
            LibraryControls(
                selectionCount: selection.count, grouped: grouping != .none,
                showGroupMenu: showGroupMenu, showSortMenu: showSortMenu
            )
            .frame(height: 52)
            .padding(.trailing, 14)
            .ignoresSafeArea()
        }
        .overlay(MarqueeLayer(rect: marquee))
        // Tabs, once there are two, at the foot of the window.
        .overlay(alignment: .bottom) {
            if navigation.tabs.count > 1 {
                LibraryTabBar(navigation: navigation, dropTab: dropTab)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.15), value: navigation.tabs.count > 1)
        // A note's file name under the card the pointer is on. Drawn over
        // the whole grid: hung from the card itself it fell behind the
        // row below.
        .overlay(HoverLabelLayer(target: menu == nil ? hovered : nil))
        .overlay(alignment: .bottom) {
            if !selection.isEmpty {
                LibrarySelectionToast(
                    move: moveSelection,
                    rename: selection.count == 1 ? { beginRename() } : nil,
                    trash: trashSelection
                )
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { toastFrame = $0 }
                .padding(.bottom, navigation.tabs.count > 1 ? 22 + 44 : 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(LibraryMotion.selectionSpring, value: selection.isEmpty)
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Rename", action: renameSelection)
            Button("Cancel", role: .cancel) {}
        }
        .overlay(carriedLayer)
        .overlay(LibraryMenuLayer(request: $menu))
        .onReceive(navigation.secondaryClicks) { secondaryClick(at: $0) }
        .onReceive(navigation.primaryClicks) { primaryClick(at: $0) }
        // Spatial's style of pointer over the whole library.
        .pointerStyle(LibraryPointer.style)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(keyCommands)
        .onAppear {
            navigation.frames = cards
            publishContext()
        }
        // A theme change redraws the library in the theme's colors.
        .id(themeGeneration)
        .onReceive(NotificationCenter.default.publisher(for: Configuration.didChangeNotification)) { _ in
            themeGeneration += 1
        }
        .task(id: folder) {
            selection.removeAll()
            cards.rects.removeAll()
            hovered = nil
            await reload(arriving: true)
            watch()
        }
        .onDisappear {
            watcher?.cancel()
            watcher = nil
        }
    }

    /// What the library follows: settings, and what agent apps are told it
    /// shows.
    private func observing(_ view: some View) -> some View {
        view
            .onChange(of: showsHidden) { Task { await reload() } }
        // What agent apps are told the library shows.
            .onChange(of: listing.folders) { publishContext() }
            .onChange(of: listing.notes) { publishContext() }
            .onChange(of: hiddenItems) { publishContext() }
            .onChange(of: selection) { publishContext() }
            .onChange(of: hovered?.url) { publishContext() }
            .onChange(of: properties) { publishContext() }
            .modifier(Arrangement(
                created: created, grouping: groupingStorage, sort: sortStorage, pins: pinStore.pins,
                changed: publishContext
            ))
            .task(id: listing.notes) { await readProperties() }
            .task(id: CreatedNeed(notes: listing.notes, wanted: grouping == .created || sort == .created)) {
                await readCreated()
            }
    }

    /// Tells of a change in how the notes are arranged. Apart from the
    /// rest of what the library follows, to keep that chain short enough
    /// for the compiler.
    private struct Arrangement: ViewModifier {
        let created: [URL: Date]
        let grouping: String
        let sort: String
        let pins: Pins
        let changed: () -> Void

        func body(content: Content) -> some View {
            content
                .onChange(of: created) { changed() }
                .onChange(of: grouping) { changed() }
                .onChange(of: sort) { changed() }
                .onChange(of: pins) { changed() }
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
        if listedFolder == nil || listedFolder == folder {
            grid
        }
    }

    @ViewBuilder private var grid: some View {
        let folders = visibleFolders
        let arranged = arrangedNotes
        let groups = arranged.groups
        // Both grids stay in place, empty or not: a card arriving in a
        // grid that arrives with it does not grow in, so the first note or
        // folder in an empty folder would just appear.
        VStack(alignment: .leading, spacing: 0) {
            // The pinned notes of this folder, above everything else.
            if let pinned = arranged.pinned {
                noteGroup(pinned)
                    .padding(.bottom, folders.isEmpty && groups.isEmpty ? 0 : 32)
            }
            folderGrid(folders)
            noteGrids(groups)
                .padding(.top, folders.isEmpty || groups.isEmpty ? 0 : 32)
        }
        if loaded, folders.isEmpty, groups.isEmpty, arranged.pinned == nil {
            Text(isFiltering ? "Nothing matches “\(query.trimmingCharacters(in: .whitespaces))”." : "No notes here yet.")
                .foregroundStyle(LibraryPalette.secondaryLabel)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 120)
        }
    }

    private func folderGrid(_ folders: [FolderListing.Folder]) -> some View {
            LazyVGrid(columns: folderColumns, alignment: .leading, spacing: 18) {
                ForEach(folders) { item in
                    FolderCard(folder: item, selected: selection.contains(item.url) || dropTarget == item.url)
                        .background(FolderCard.shadow)
                        // A drag held over a folder lifts it, as a hover does.
                        .scaleEffect(dropTarget == item.url ? 1.04 : 1)
                        .opacity(hiddenItems.contains(item.url) ? Self.hiddenOpacity : 1)
                        .modifier(CardClick(hover: { if $0 { ListingCache.prefetch(item.url, showsHidden: showsHidden) } }) { click(item.url) { go(to: item.url) } })
                        .modifier(FolderDrop(folder: item.url, targeted: dropBinding(item.url)) { dropped() })
                        // A middle click opens the folder in a new tab behind, as a link in a browser.
                        .overlay(MiddleClick { navigation.openTab(item.url, behind: true) })
                        .modifier(CardFrame(url: item.url, frames: cards))
                        .matchedGeometryEffect(id: item.url, in: liftSpace)
                        .transition(inFlight.contains(item.url) ? .identity : Self.cardTransition)
                }
            }
    }

    @ViewBuilder private func noteGrids(_ groups: [NoteGroup]) -> some View {
        if groups.count <= 1, groups.first?.title.isEmpty ?? true {
            // Ungrouped: one grid straight in the page; a grid inside the
            // groups' loop dropped the cards' grow-in.
            LazyVGrid(columns: noteColumns, alignment: .leading, spacing: 18) {
                ForEach(groups.first?.notes ?? []) { item in noteCard(item) }
            }
        } else {
            VStack(alignment: .leading, spacing: 32) {
                ForEach(groups) { group in noteGroup(group) }
            }
        }
    }

    /// A heading over its cards.
    private func noteGroup(_ group: NoteGroup) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            NoteGroupHeading(group: group)
            LazyVGrid(columns: noteColumns, alignment: .leading, spacing: 18) {
                ForEach(group.notes) { item in noteCard(item) }
            }
        }
    }

    private func noteCard(_ item: FolderListing.Note) -> some View {
        LibraryNoteTile(note: item, selected: selection.contains(item.url))
            .modifier(NoteShadow())
            .opacity(hiddenItems.contains(item.url) ? Self.hiddenOpacity : 1)
            .modifier(CardClick(hover: { hover(item.url, $0) }) { click(item.url) { openNote(item.url) } })
            .modifier(CardFrame(url: item.url, frames: cards))
            .matchedGeometryEffect(id: item.url, in: liftSpace)
            .transition(inFlight.contains(item.url) ? .identity : Self.cardTransition)
    }

    // MARK: Drag and drop

    /// Lifts the card, and the others picked with it when it is picked,
    /// out of the grid: the grid closes up behind them and they follow
    /// the pointer, the grabbed card under it as it was grabbed.
    private func pickUp(_ url: URL, frame: CGRect, at point: CGPoint) {
        let urls = selection.contains(url)
            ? [url] + selection.filter { $0 != url }.sorted { $0.path < $1.path }
            : [url]
        hovered = nil
        // First, without animation, the cards' leaving is made a flight
        // rather than a shrink; then they leave.
        inFlight.formUnion(urls)
        let sizes = Dictionary(uniqueKeysWithValues: urls.map { ($0, cards.rects[$0]?.size ?? frame.size) })
        let grab = CGSize(width: point.x - frame.midX, height: point.y - frame.midY)
        DispatchQueue.main.async {
            guard dragMode == .cards else { return }
            withAnimation(Self.lift) {
                carried = CarriedCards(urls: urls, sizes: sizes, grab: grab, point: point)
            }
        }
    }

    private func carry(to point: CGPoint) {
        // Out of the window, the cards become a drag of their files.
        if carried != nil, let window = navigation.window, LibraryDrag.pointerLeft(window), handOff(from: window) { return }
        carried?.point = point
        let over = cards.rects.first { url, rect in
            rect.contains(point) && listing.folders.contains { $0.url == url } && carried?.urls.contains(url) != true
        }?.key
        let tab = over == nil ? LibraryDrag.shared.tabFrames.first { $0.value.contains(point) }?.key : nil
        if over != dropTarget || tab != dropTab {
            withAnimation(.spring(duration: 0.22, bounce: 0.2)) {
                dropTarget = over
                dropTab = tab
            }
        }
    }

    /// Gives the carried cards to the system to drag, and lets them back
    /// into the grid: they stay in their folder until a drop moves them,
    /// when the folder's watcher takes them off the page.
    private func handOff(from window: NSWindow) -> Bool {
        guard let carried else { return false }
        var pictures: [URL: NSImage] = [:]
        for url in carried.urls {
            let size = carried.sizes[url] ?? .zero
            let renderer = ImageRenderer(
                content: carriedCard(url).frame(width: size.width, height: size.height).environment(\.colorScheme, colorScheme)
            )
            renderer.scale = window.backingScaleFactor
            pictures[url] = renderer.nsImage
        }
        let began = LibraryDrag.shared.handOff(carried, pictures: pictures, from: window) {
            // The mouse came up in the system's drag, not in the gesture.
            dragMode = nil
            dragEnded = Date()
            Task { await reload() }
        }
        guard began else { return false }
        dragMode = .ignored
        withAnimation(.spring(duration: 0.22, bounce: 0.2)) {
            dropTarget = nil
            dropTab = nil
        }
        withAnimation(Self.lift) { self.carried = nil }
        settle(carried.urls)
        return true
    }

    /// Over a folder or a tab, the cards sink into it and move there;
    /// anywhere else they fly back to their places.
    private func letGo() {
        guard let carried else {
            inFlight.removeAll()
            return
        }
        let tabFolder = dropTab.flatMap { id in navigation.tabs.first { $0.id == id }?.folder }
        let target = dropTarget ?? tabFolder
        let targetFrame = dropTarget.flatMap { cards.rects[$0] } ?? dropTab.flatMap { LibraryDrag.shared.tabFrames[$0] }
        guard let target, let targetFrame else {
            withAnimation(Self.lift) { self.carried = nil }
            settle(carried.urls)
            return
        }
        withAnimation(.easeIn(duration: 0.2)) {
            self.carried?.sinking = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
            dropTarget = nil
            dropTab = nil
        }
        let moving = LibraryDrag.movable(carried.urls, into: target)
        selection.subtract(carried.urls)
        Task {
            await Task.detached { for url in moving { try? NoteFile.move(url, into: target) } }.value
            await reload()
            // Any that could not go come back into the grid.
            withAnimation(Self.lift) { self.carried = nil }
            settle(carried.urls)
        }
    }

    /// Once the cards have landed, they grow and shrink again as cards do.
    private func settle(_ urls: [URL]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if carried == nil { inFlight.subtract(urls) }
        }
    }

    static let lift = Animation.spring(duration: 0.32, bounce: 0.18)

    /// The carried cards over everything, the grabbed one on top and the
    /// rest fanned a little behind it.
    private var carriedLayer: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let carried {
                ForEach(Array(carried.urls.enumerated().reversed()), id: \.element) { index, url in
                    let size = carried.sizes[url] ?? .zero
                    let fan = CGFloat(min(index, 3))
                    carriedCard(url)
                        .frame(width: size.width, height: size.height)
                        .matchedGeometryEffect(id: url, in: liftSpace)
                        .rotationEffect(.degrees(index == 0 ? 0 : (index % 2 == 1 ? -3 : 3)))
                        .shadow(color: .black.opacity(carried.sinking == nil ? 0.16 : 0), radius: 18, y: 12)
                        .scaleEffect(carried.sinking == nil ? 1.04 : 0.12)
                        .opacity(carried.sinking == nil ? 1 : 0)
                        .position(carried.sinking ?? CGPoint(
                            x: carried.point.x - carried.grab.width + fan * 4,
                            y: carried.point.y - carried.grab.height + fan * 4
                        ))
                        .transition(.identity)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder private func carriedCard(_ url: URL) -> some View {
        if let folder = listing.folders.first(where: { $0.url == url }) {
            FolderCard(folder: folder).background(FolderCard.shadow)
        } else if let note = listing.notes.first(where: { $0.url == url }) {
            LibraryNoteTile(note: note, selected: false).modifier(NoteShadow())
        }
    }

    private func dropBinding(_ url: URL) -> Binding<Bool> {
        Binding(
            get: { dropTarget == url },
            set: { over in
                if over { dropTarget = url } else if dropTarget == url { dropTarget = nil }
            }
        )
    }

    /// After a drop: what was picked has gone, and the grid closes up.
    private func dropped() {
        deselect()
        Task { await reload() }
    }

    // MARK: Grouping and search

    private var isFiltering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var visibleFolders: [FolderListing.Folder] {
        guard listedFolder == nil || listedFolder == folder else { return [] }
        let away = Set(carried?.urls ?? [])
        return listing.folders.filter { !away.contains($0.url) && LibraryOrganize.matches(query, name: $0.name) }
    }

    private var visibleNotes: [FolderListing.Note] {
        guard listedFolder == nil || listedFolder == folder else { return [] }
        let away = Set(carried?.urls ?? [])
        return listing.notes.filter { !away.contains($0.url) && LibraryOrganize.matches(query, name: $0.url.lastPathComponent, title: $0.title) }
    }

    private var grouping: LibraryGrouping { LibraryGrouping(storage: groupingStorage) }
    private var sort: LibrarySort { LibrarySort(storage: sortStorage) }

    /// The notes as the page draws them: the pinned ones in a group of
    /// their own, then the rest in their groups, all in the sort chosen.
    private var arrangedNotes: (pinned: NoteGroup?, groups: [NoteGroup]) {
        var grouping = grouping
        // A property no note here has groups nothing; show the plain list.
        if case .property(let key) = grouping, !properties.values.contains(where: { $0[key] != nil }) { grouping = .none }
        let sorted = LibraryOrganize.sorted(visibleNotes, by: sort, created: created)
        let pins = pinStore.pins
        let split = LibraryOrganize.split(sorted) { pins.contains($0) }
        let groups = LibraryOrganize.groups(split.rest, by: grouping, properties: properties, created: created)
        let pinned = split.pinned.isEmpty ? nil : NoteGroup(id: "\u{0}pinned", title: "Pinned", notes: split.pinned)
        return (pinned, groups)
    }

    /// Every note shown, in the order drawn.
    private var orderedNotes: [FolderListing.Note] {
        let arranged = arrangedNotes
        return (arranged.pinned?.notes ?? []) + arranged.groups.flatMap(\.notes)
    }

    /// What the creation dates are read for: these notes, when wanted.
    private struct CreatedNeed: Equatable {
        let notes: [FolderListing.Note]
        let wanted: Bool
    }

    /// Reads when the notes shown were made, off the main thread.
    private func readCreated() async {
        guard grouping == .created || sort == .created else { return }
        let notes = listing.notes.map(\.url)
        let folder = folder
        let read = await Task.detached(priority: .utility) { NoteDates.created(notes) }.value
        guard folder == self.folder, read != created else { return }
        created = read
    }

    /// Reads the frontmatter of the notes shown, off the main thread.
    private func readProperties() async {
        let notes = listing.notes.map(\.url)
        let folder = folder
        let read = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: notes.map { ($0.standardizedFileURL, NoteProperties.read($0)) })
        }.value
        guard folder == self.folder, read != properties else { return }
        properties = read
    }

    private func publishContext() {
        navigation.snapshot = LibrarySnapshot(
            folders: visibleFolders,
            notes: orderedNotes,
            hidden: hiddenItems, selection: selection, hovered: hovered?.url
        )
    }

    private func hover(_ url: URL, _ on: Bool) {
        if on, let frame = cards.rects[url] {
            hovered = HoverTarget(url: url, text: url.lastPathComponent, card: frame)
        } else if hovered?.url == url {
            hovered = nil
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
    /// A drag begun on a card carries the card; one begun on empty space
    /// draws the rubber band: every card it touches is picked, on top of
    /// what was picked before when ⌘ is held.
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { value in
                guard menu == nil else { return }
                if dragMode == nil {
                    if let (url, rect) = cards.rects.first(where: { $0.value.contains(value.startLocation) }) {
                        dragMode = .cards
                        pickUp(url, frame: rect, at: value.startLocation)
                    } else if onChrome(value.startLocation) {
                        dragMode = .ignored
                    } else {
                        dragMode = .marquee
                        let adding = !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty
                        marqueeBase = adding ? selection : []
                    }
                }
                if dragMode == .cards {
                    carry(to: value.location)
                    return
                }
                guard dragMode == .marquee else { return }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y)
                )
                marquee = rect
                let touched = cards.rects.filter { $0.value.intersects(rect) }.map(\.key)
                selection = marqueeBase.union(touched)
            }
            .onEnded { _ in
                let mode = dragMode
                dragMode = nil
                dragEnded = Date()
                if mode == .cards { letGo() }
                marquee = nil
            }
    }

    private func deselect() { selection.removeAll() }

    /// The scroller at the right edge, the toast and the tab bar take
    /// their own drags; none draws the band.
    private func onChrome(_ point: CGPoint) -> Bool {
        point.x > width - 16 || toastFrame.contains(point)
            || LibraryDrag.shared.tabFrames.values.contains { $0.insetBy(dx: -6, dy: -6).contains(point) }
    }

    /// A click on empty space lets go of what is picked. Cards and the
    /// toast answer their own clicks; a menu or a dialog that is up takes
    /// the click for itself.
    private func primaryClick(at point: CGPoint) {
        guard !selection.isEmpty, menu == nil, !renaming else { return }
        // With ⌘ or ⇧ held, the press may begin a drag that adds to it.
        guard NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
        guard !toastFrame.contains(point), !cards.rects.values.contains(where: { $0.contains(point) }) else { return }
        deselect()
    }

    private func selectAll() {
        selection = Set(visibleFolders.map(\.url) + visibleNotes.map(\.url))
    }

    /// Spatial's create and delete: a new card grows out of a point with a
    /// little spring; a deleted one shrinks to its center as it fades,
    /// quickly, and the grid closes up behind it.
    static let cardTransition = AnyTransition.asymmetric(
        insertion: .scale(scale: 0.05).combined(with: .opacity)
            .animation(.spring(duration: 0.3, bounce: 0.22)),
        removal: .scale(scale: 0.05).combined(with: .opacity)
            .animation(.timingCurve(0.4, 0, 0.7, 1, duration: 0.18))
    )

    /// To the Trash, so it can be put back, and off the grid at once
    /// rather than when the folder watcher next hears of it.
    private func trash(_ urls: [URL]) {
        NSWorkspace.shared.recycle(urls) { moved, _ in
            let gone = Set(moved.keys)
            Task { @MainActor in
                guard !gone.isEmpty else { return }
                withAnimation(.spring(duration: 0.4, bounce: 0.12)) {
                    listing.folders.removeAll { gone.contains($0.url) }
                    listing.notes.removeAll { gone.contains($0.url) }
                }
                selection.subtract(gone)
                if let url = hovered?.url, gone.contains(url) { hovered = nil }
            }
        }
    }

    private func trashSelection() {
        guard !selection.isEmpty else { return }
        trash(Array(selection))
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
        // Not a folder into itself or below itself, and not an item into
        // the folder it is already in, which would only renumber it.
        let moving = LibraryDrag.movable(Array(selection), into: destination)
        deselect()
        // Off the main thread: a coordinated move waits on any window
        // showing the note, and that window answers on the main thread.
        Task {
            await Task.detached { for url in moving { try? NoteFile.move(url, into: destination) } }.value
            await reload()
        }
    }

    /// Renames the one picked card, or the card a menu was opened on.
    private func beginRename(_ target: URL? = nil) {
        guard let url = target ?? selection.first else { return }
        renameTarget = url
        let isFolder = listing.folders.contains { $0.url == url }
        renameText = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        renaming = true
    }

    private func renameSelection() {
        guard let url = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, !name.hasPrefix(".") else { return }
        let isFolder = listing.folders.contains { $0.url == url }
        deselect()
        // Off the main thread, as a move is.
        Task {
            await Task.detached { _ = try? NoteFile.rename(url, to: name, isFolder: isFolder) }.value
            await reload()
        }
    }

    // MARK: Menu

    /// A right click closes an open menu; otherwise it opens the menu of
    /// the card under it, or of the folder shown on empty space.
    private func secondaryClick(at point: CGPoint) {
        if menu != nil {
            withAnimation(LibraryMenuLayer.wash) { menu = nil }
            return
        }
        if let url = cards.rects.first(where: { $0.value.contains(point) })?.key {
            // As in Spatial, the card asked about is picked, and stays
            // picked once the menu closes; a card already among those
            // picked keeps the rest with it.
            if !selection.contains(url) { selection = [url] }
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

    /// The grouping's menu, under its button: its right edge on the
    /// button's; the menu turns left at the window's edge.
    private func showGroupMenu(under frame: CGRect) {
        if menu != nil {
            withAnimation(LibraryMenuLayer.wash) { menu = nil }
            return
        }
        var choices: [LibraryGrouping] = [.none, .modified, .created, .name]
        choices += LibraryOrganize.groupableKeys(properties).map { .property($0) }
        let items = choices.map { choice in
            LibraryMenuItem(title: choice.title, glyph: choice.glyph, hint: choice == grouping ? "✓" : "") {
                withAnimation(LibraryMotion.itemSpring) { groupingStorage = choice.storage }
            }
        }
        showMenu(at: CGPoint(x: frame.maxX, y: frame.maxY + 4), items: items)
    }

    private func showSortMenu(under frame: CGRect) {
        if menu != nil {
            withAnimation(LibraryMenuLayer.wash) { menu = nil }
            return
        }
        let items = LibrarySort.allCases.map { choice in
            LibraryMenuItem(title: choice.title, glyph: choice.glyph, hint: choice == sort ? "✓" : "") {
                withAnimation(LibraryMotion.itemSpring) { sortStorage = choice.rawValue }
            }
        }
        showMenu(at: CGPoint(x: frame.maxX, y: frame.maxY + 4), items: items)
    }

    /// Pin or Unpin for a note: the note asked about, and the other
    /// notes picked with it. Unpin when the note asked about is pinned.
    private func pinItem(for url: URL) -> LibraryMenuItem {
        let notes = Set(listing.notes.map(\.url))
        let targets = selection.contains(url) ? selection.filter { notes.contains($0) } : [url]
        let unpin = pinStore.pins.contains(url)
        return LibraryMenuItem(title: unpin ? "Unpin" : "Pin", glyph: PinGlyph()) {
            withAnimation(LibraryMotion.itemSpring) {
                for target in targets where pinStore.pins.contains(target) == unpin { pinStore.toggle(target) }
            }
        }
    }

    private func items(for url: URL, isFolder: Bool) -> [LibraryMenuItem] {
        [
            LibraryMenuItem(title: "Open", glyph: OpenGlyph()) {
                isFolder ? go(to: url) : openNote(url)
            },
        ] + (isFolder ? [
            LibraryMenuItem(title: "Open in New Tab", glyph: OpenGlyph()) { navigation.openTab(url) },
        ] : [pinItem(for: url)]) + [
            LibraryMenuItem(title: "Reveal in Finder", glyph: RevealGlyph()) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            LibraryMenuItem(title: "Rename", glyph: PencilGlyph()) { beginRename(url) },
            LibraryMenuItem(title: "Copy Path", glyph: CopyGlyph()) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            },
            LibraryMenuItem(title: "Move to Trash", glyph: TrashGlyph()) {
                // Recoverable; the folder watcher takes the card away.
                trash([url])
            },
        ]
    }

    private var emptySpaceItems: [LibraryMenuItem] {
        [
            LibraryMenuItem(title: "New Note", glyph: ComposeGlyph()) { newNote() },
            LibraryMenuItem(title: "New Folder", glyph: FolderGlyph(), badged: true) { newFolder() },
            LibraryMenuItem(title: "Reveal in Finder", glyph: RevealGlyph()) {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            },
            LibraryMenuItem(
                title: showsHidden ? "Hide Hidden Items" : "Show Hidden Items", glyph: EyeGlyph(), hint: "⇧⌘."
            ) { showsHidden.toggle() },
        ]
    }

    /// An empty `Untitled.md`, numbered when the name is taken, left
    /// closed: it shows in the grid first, and a click opens it. Once it
    /// has a title it takes its name from it (NoteNaming).
    private func newNote() {
        let url = LibraryNames.unused("Untitled", extension: "md", in: folder)
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { return }
        // The card grows into the grid; a click opens it.
        Task { await reload() }
    }

    /// `Untitled Folder`, numbered when taken, as Finder names one.
    private func newFolder() {
        let url = LibraryNames.unused("Untitled Folder", extension: "", in: folder)
        guard (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)) != nil else { return }
        Task { await reload() }
    }

    /// Hidden items show faintly, as a hint that they are usually away.
    private static let hiddenOpacity: Double = 0.4

    /// ⌘↑ to the enclosing folder, ⌘[ back and ⌘] forward, as in Finder,
    /// and the library's other keys. The buttons are hidden; only their
    /// keys act, and none while a menu or the rename dialog is up.
    private var keyCommands: some View {
        ZStack {
            Button("Show Hidden Items") { showsHidden.toggle() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Enclosing Folder") { goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Back") { goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { goForward() }
                .keyboardShortcut("]", modifiers: .command)
            Button("Select All") { if idle { selectAll() } }
                .keyboardShortcut("a", modifiers: .command)
            // Escape lets go of what is picked; with nothing picked it
            // steps back, as ⌃T does, after vim's tag stack.
            Button("Deselect or Back") { if idle { selection.isEmpty ? stepBack() : deselect() } }
                .keyboardShortcut(.escape, modifiers: [])
            // ⌘N here makes a blank note in the folder shown, which grows
            // into the grid, newest first, ready to click into. Elsewhere
            // ⌘N is File ▸ New as before.
            Button("New Note Here") { newNote() }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Tab") { navigation.openTab() }
                .keyboardShortcut("t", modifiers: .command)
            // ⌘W closes the tab in front, and the window with its last.
            Button("Close Tab") { if !navigation.closeTab() { navigation.window?.performClose(nil) } }
                .keyboardShortcut("w", modifiers: .command)
            Button("Next Tab") { navigation.showNextTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { navigation.showNextTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            ForEach(1..<10) { number in
                Button("Tab \(number)") { navigation.showTab(number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
            Button("Step Back") { stepBack() }
                .keyboardShortcut("t", modifiers: .control)
            Button("Move to Trash") { if idle { trashSelection() } }
                .keyboardShortcut(.delete, modifiers: .command)
            // Delete alone does the same: to the Trash, so it can be put
            // back, never removed outright.
            Button("Delete") { if idle { trashSelection() } }
                .keyboardShortcut(.delete, modifiers: [])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// No menu and no dialog up: the grid's keys may act.
    private var idle: Bool { menu == nil && !renaming }

    // MARK: Navigation

    private func go(to target: URL) { navigation.go(to: target) }
    private func goUp() { navigation.goUp() }
    /// Back to the folder this one was reached from, or, with no history
    /// (a folder opened deep, or the way back already taken), up to its
    /// parent; never above the folder opened.
    private func stepBack() {
        guard menu == nil, !renaming else { return }
        navigation.canGoBack ? navigation.goBack() : navigation.goUp()
    }
    private func goBack() { navigation.goBack() }
    private func goForward() { navigation.goForward() }

    /// Opens a note in its own window.
    private func openNote(_ url: URL) {
        LibraryOpening.open([url])
    }

    // MARK: Loading

    /// Reads the folder and shows what changed. A change in the folder
    /// shown animates; arriving in a folder does not, and shows the
    /// folder as last read at once while it is read again, so moving in
    /// and out never waits on the disk or on hundreds of cards animating.
    private func reload(arriving: Bool = false) async {
        let folder = folder
        let showsHidden = showsHidden
        if arriving {
            if let known = ListingCache.get(folder, showsHidden: showsHidden) {
                show(known, animated: false)
                listedFolder = folder
            }
        }
        let fresh = await ListingCache.read(folder, showsHidden: showsHidden)
        guard folder == self.folder, showsHidden == self.showsHidden else { return }
        // An untitled note that has been given a title takes its name;
        // the folder watcher then reads the folder again.
        let untitled = fresh.listing.notes.filter { NoteNaming.isUntitled($0.url) }
        // One rename at a time per note: reloads come in bursts, and two
        // passes over the same note would race to the same new name.
        let naming = untitled.map(\.url).filter { !Self.naming.contains($0) }
        if !naming.isEmpty {
            Self.naming.formUnion(naming)
            Task.detached {
                NoteNaming.nameFromTitles(naming)
                await MainActor.run { Self.naming.subtract(naming) }
            }
        }
        show(fresh, animated: loaded && !arriving && listedFolder == folder)
        listedFolder = folder
        loaded = true
    }

    /// Untitled notes being named from their titles now.
    private static var naming = Set<URL>()

    private func show(_ entry: ListingCache.Entry, animated: Bool) {
        guard entry.listing.folders != listing.folders || entry.listing.notes != listing.notes
                || entry.hidden != hiddenItems else { return }
        var transaction = Transaction(animation: animated ? LibraryMotion.itemSpring : nil)
        transaction.disablesAnimations = !animated
        withTransaction(transaction) {
            listing = entry.listing
            hiddenItems = entry.hidden
        }
        // Cards moved away (by Finder, or another window) are no longer
        // picked.
        let shown = Set(entry.listing.folders.map(\.url) + entry.listing.notes.map(\.url))
        if !selection.isSubset(of: shown) { selection.formIntersection(shown) }
        if let url = hovered?.url, !shown.contains(url) { hovered = nil }
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
                // A card flung past is never drawn; the rest take turns,
                // with room between them for the scroll to draw.
                try? await Task.sleep(for: .milliseconds(70))
                guard !Task.isCancelled else { return }
                await NoteMiniature.turn()
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
    /// Told when the pointer comes onto the card and leaves it, so the
    /// library can show the card's name under it.
    var hover: ((Bool) -> Void)?
    let open: () -> Void
    @State private var hovering = false

    init(hover: ((Bool) -> Void)? = nil, open: @escaping () -> Void) {
        self.hover = hover
        self.open = open
    }

    func body(content: Content) -> some View {
        Button(action: open) { content }
            .buttonStyle(PressStyle(hovering: hovering))
            .onHover {
                hovering = $0
                hover?($0)
            }
            // A button would otherwise bring back the system's arrow.
            .pointerStyle(LibraryPointer.style)
            // The grown card draws over its neighbors.
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

@MainActor
final class CardFrames {
    var rects: [URL: CGRect] = [:]
}

private struct CardFrame: ViewModifier {
    let url: URL
    let frames: CardFrames

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.rects[url] = $0 }
            .onDisappear { frames.rects[url] = nil }
    }
}
