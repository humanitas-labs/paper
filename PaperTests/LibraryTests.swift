import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Paper

/// The desktop library (.plan/desktop-library.md): what a folder lists, how
/// folders are told from files, and the miniatures on the note cards.
@MainActor
struct LibraryTests {
    /// A folder with two subfolders, two notes, a hidden file, a package
    /// and a file that is not a note.
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryTests-\(UUID().uuidString)", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("Beta/Inner"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Bundle.rtfd"), withIntermediateDirectories: true)
        try "# Older note\n\nText.".write(to: root.appendingPathComponent("old.md"), atomically: true, encoding: .utf8)
        try "---\ntitle: x\n---\n# Newer note\n".write(to: root.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        try "plain".write(to: root.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: root.appendingPathComponent("image.png"))
        try "x".write(to: root.appendingPathComponent("Beta/one.md"), atomically: true, encoding: .utf8)
        let older = Date(timeIntervalSinceNow: -3600)
        try manager.setAttributes([.modificationDate: older], ofItemAtPath: root.appendingPathComponent("old.md").path)
        return root
    }

    @Test func listsFoldersByNameThenNotesNewestFirst() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = FolderListing.load(root, isDefaultRoot: false)
        #expect(listing.folders.map(\.name) == ["alpha", "Beta"])
        #expect(listing.folders.map(\.itemCount) == [0, 2])
        #expect(listing.notes.map(\.title) == ["Newer note", "Older note"])
    }

    @Test func hiddenItemsJoinTheListingAndAreMarked() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".config"), withIntermediateDirectories: true)
        let (listing, hidden) = FolderListing.loadIncludingHidden(root)
        #expect(listing.folders.map(\.name).contains(".config"))
        #expect(listing.notes.map(\.url.lastPathComponent).contains(".hidden.md"))
        #expect(Set(hidden.map(\.lastPathComponent)) == [".config", ".hidden.md"])
        // The visible items are all still there and not marked.
        #expect(listing.folders.count == 3)
        #expect(listing.notes.count == 3)
    }

    /// Agent apps see the folder shown as a list of rows, the picked
    /// ones selected, with Paper's own line for it.
    @Test func libraryIsReportedToAgentApps() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let navigation = LibraryNavigation(root: root)
        let listing = FolderListing.load(root, isDefaultRoot: false)
        let picked = try #require(listing.notes.first).url
        navigation.snapshot = LibrarySnapshot(
            folders: listing.folders, notes: listing.notes, selection: [picked], hovered: listing.folders.first?.url
        )
        let context = PaperContext(textViews: { [] }, libraries: { [navigation] })
        let window = try #require(context.current().children.first)
        #expect(window.role == .window && window.subrole == "library" && window.focused)
        let list = try #require(window.children.first)
        #expect(list.role == .list && list.subrole == "folder" && list.title == root.lastPathComponent)
        #expect(list.children.map(\.subrole) == ["folder", "folder", "note", "note"])
        #expect(list.children.filter(\.selected).map(\.url) == [picked.absoluteString])
        #expect(list.children.filter(\.hovered).count == 1)
        #expect(context.display()?.title == root.lastPathComponent)
        #expect(context.display()?.detail == picked.lastPathComponent)
        // Ids hold from one answer to the next.
        #expect(context.current().children.first?.children.first?.children.map(\.id) == list.children.map(\.id))
        // A card's place is asked of the grid; with no window it is gone.
        #expect(context.locate(list.children[0].id)?.state == .gone)
    }

    @Test func untitledNotesTakeTheirNameFromAFinishedTitle() throws {
        #expect(NoteNaming.kebab("Where to Begin?") == "where-to-begin")
        #expect(NoteNaming.kebab("Café  Société — Notes") == "cafe-societe-notes")
        #expect(NoteNaming.finishedTitle(in: "# Half typ") == nil)
        #expect(NoteNaming.finishedTitle(in: "# Where to Begin?\n") == "Where to Begin?")
        #expect(NoteNaming.finishedTitle(in: "---\ntitle: x\n---\n# Plan\nText") == "Plan")
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let named = root.appendingPathComponent("Untitled.md")
        let half = root.appendingPathComponent("Untitled 2.md")
        let byHand = root.appendingPathComponent("mine.md")
        try "# Where to Begin?\n\nText".write(to: named, atomically: true, encoding: .utf8)
        try "# Still typ".write(to: half, atomically: true, encoding: .utf8)
        try "# Something Else\n".write(to: byHand, atomically: true, encoding: .utf8)
        NoteNaming.nameFromTitles([named, half, byHand])
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(names.contains("where-to-begin.md"))
        #expect(!names.contains("Untitled.md"))
        #expect(names.contains("Untitled 2.md"))
        #expect(names.contains("mine.md"))
    }

    @Test func tabsKeepTheirOwnFolderAndHistory() {
        let root = URL(fileURLWithPath: "/tmp/lib")
        let navigation = LibraryNavigation(root: root)
        navigation.go(to: root.appendingPathComponent("a"))
        navigation.openTab(root.appendingPathComponent("b"))
        #expect(navigation.tabs.count == 2 && navigation.front == 1)
        #expect(navigation.folder.lastPathComponent == "b" && !navigation.canGoBack)
        navigation.showTab(0)
        #expect(navigation.folder.lastPathComponent == "a" && navigation.canGoBack)
        navigation.openTab(root.appendingPathComponent("c"), behind: true)
        #expect(navigation.front == 0 && navigation.tabs.map { $0.folder.lastPathComponent } == ["a", "c", "b"])
        navigation.showNextTab(-1)
        #expect(navigation.folder.lastPathComponent == "b")
        #expect(navigation.closeTab())
        #expect(navigation.tabs.count == 2 && navigation.folder.lastPathComponent == "c")
        #expect(navigation.closeTab())
        #expect(!navigation.closeTab())
        #expect(navigation.tabs.count == 1)
        // ⌘T starts at the library's root, wherever the front tab is.
        navigation.go(to: root.appendingPathComponent("a/deep"))
        navigation.openTab()
        #expect(navigation.folder == root.standardizedFileURL && !navigation.canGoBack)
    }

    @Test func foldersAreToldFromFilesAndPackages() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(LibraryOpening.isFolder(root))
        #expect(LibraryOpening.isFolder(root.appendingPathComponent("Beta")))
        #expect(!LibraryOpening.isFolder(root.appendingPathComponent("old.md")))
        #expect(!LibraryOpening.isFolder(root.appendingPathComponent("Bundle.rtfd")))
        #expect(!LibraryOpening.isFolder(root.appendingPathComponent("missing")))
    }

    @Test func miniatureIsAPageOfTheNoteInEachAppearance() throws {
        let text = "# A heading\n\nA paragraph of text that should leave ink on the page.\n\n- one\n- two\n"
        var means: [Bool: Double] = [:]
        for dark in [false, true] {
            let background = dark ? NSColor.black : NSColor.white
            let image = NoteMiniature.render(text, documentURL: nil, dark: dark, background: background)
            #expect(image.size.width == NoteMiniature.pageWidth)
            #expect(abs(image.size.height - NoteMiniature.pageWidth / NoteMiniature.aspect) <= 1)
            let rep = try #require(image.representations.first as? NSBitmapImageRep)
            #expect(rep.pixelsWide == Int(NoteMiniature.pageWidth * 2))
            means[dark] = Self.meanBrightness(rep)
            // Text leaves ink: the page is not one flat color.
            #expect(Self.distinctBrightness(rep) > 8)
        }
        // Light pages are light and dark pages dark.
        #expect(try #require(means[false]) > 0.8)
        #expect(try #require(means[true]) < 0.2)
    }

    /// The open animation carries the page's text over a changing ground,
    /// so a clear background must come out clear.
    @Test func miniatureOnAClearGroundIsTextAlone() throws {
        let image = NoteMiniature.render("# A heading\n\nSome text.\n", documentURL: nil, dark: false, background: .clear)
        let rep = try #require(image.representations.first as? NSBitmapImageRep)
        #expect(rep.colorAt(x: 4, y: 4)?.alphaComponent == 0)
        #expect(rep.colorAt(x: rep.pixelsWide - 4, y: rep.pixelsHigh - 4)?.alphaComponent == 0)
        var inked = false
        for y in stride(from: 80, to: 400, by: 2) where !inked {
            for x in stride(from: 90, to: 500, by: 2) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked = true }
        }
        #expect(inked)
        // The text starts at the preview's own margins, not the editor's
        // window margins.
        var left = rep.pixelsWide, top = rep.pixelsHigh
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                left = min(left, x)
                top = min(top, y)
            }
        }
        #expect(Double(left) / 2 >= NoteMiniature.margins.width - 2 && Double(left) / 2 <= NoteMiniature.margins.width + 6)
        #expect(Double(top) / 2 >= NoteMiniature.margins.height - 2 && Double(top) / 2 <= NoteMiniature.margins.height + 24)
    }

    /// The pointer's 2x bitmap must be drawn at full size: ink reaches
    /// past the middle of it, not only into one quarter.
    @Test func pointerFillsItsBitmapAtBothScales() throws {
        let reps = LibraryPointer.image.representations.compactMap { $0 as? NSBitmapImageRep }
        #expect(reps.map(\.pixelsWide).sorted() == [24, 48])
        for rep in reps {
            #expect(rep.size == LibraryPointer.size)
            var farthest = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                    farthest = max(farthest, x)
                }
            }
            #expect(Double(farthest) > Double(rep.pixelsWide) * 0.7)
        }
    }

    @Test func miniatureIsCachedUntilTheNoteChanges() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("old.md")
        let date = Date(timeIntervalSince1970: 1_000)
        let first = NoteMiniature.image(for: note, modified: date, dark: false, background: .white)
        let again = NoteMiniature.image(for: note, modified: date, dark: false, background: .white)
        #expect(first != nil)
        #expect(first === again)
        let changed = NoteMiniature.image(for: note, modified: date.addingTimeInterval(1), dark: false, background: .white)
        #expect(changed !== first)
    }

    /// The folder's front panel is the note card's color in the theme, in
    /// both appearances. Both are drawn by the same renderer and read
    /// back the same way, so they compare like for like.
    @Test(arguments: [false, true]) func folderFrontMatchesTheNoteCard(dark: Bool) throws {
        let scheme: ColorScheme = dark ? .dark : .light
        let folder = FolderListing.Folder(url: URL(fileURLWithPath: "/tmp/x"), name: "", itemCount: 0)
        let front = try Self.pixel(FolderCard(folder: folder).frame(width: 291, height: 205.45).environment(\.colorScheme, scheme), x: 0.75, y: 0.75)
        let card = try Self.pixel(Rectangle().fill(LibraryPalette.card).frame(width: 40, height: 40).environment(\.colorScheme, scheme), x: 0.5, y: 0.5)
        let tolerance: CGFloat = 2 / 255
        #expect(abs(front.redComponent - card.redComponent) <= tolerance)
        #expect(abs(front.greenComponent - card.greenComponent) <= tolerance)
        #expect(abs(front.blueComponent - card.blueComponent) <= tolerance)
    }

    private static func pixel(_ view: some View, x: CGFloat, y: CGFloat) throws -> NSColor {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        return try #require(rep.colorAt(x: Int(CGFloat(rep.pixelsWide) * x), y: Int(CGFloat(rep.pixelsHigh) * y)))
    }

    @Test func notesGroupByDateNameAndProperty() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func note(_ name: String, daysAgo: Double) -> FolderListing.Note {
            FolderListing.Note(url: URL(fileURLWithPath: "/n/\(name).md"), title: name, modified: now.addingTimeInterval(-daysAgo * 86_400))
        }
        let notes = [note("beta", daysAgo: 0), note("alpha", daysAgo: 1), note("Émile", daysAgo: 3), note("2026", daysAgo: 400)]
        let byDate = LibraryOrganize.groups(notes, by: .modified, now: now, calendar: calendar)
        #expect(byDate.map(\.title).prefix(3) == ["Today", "Yesterday", "Previous 7 Days"])
        #expect(byDate.count == 4)
        let byName = LibraryOrganize.groups(notes, by: .name, now: now, calendar: calendar)
        #expect(byName.map(\.title) == ["A", "B", "E", "#"])
        let properties: [URL: [String: String]] = [
            URL(fileURLWithPath: "/n/beta.md"): ["status": "draft"],
            URL(fileURLWithPath: "/n/alpha.md"): ["status": "done"],
        ]
        let byStatus = LibraryOrganize.groups(notes, by: .property("status"), properties: properties)
        #expect(byStatus.map(\.title) == ["done", "draft", "No status"])
        #expect(byStatus.last?.notes.count == 2)
        #expect(LibraryOrganize.groups(notes, by: .none).first?.notes == notes)
        #expect(LibraryGrouping(storage: LibraryGrouping.property("type").storage) == .property("type"))
    }

    @Test func notesSortByChangeCreationAndName() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func note(_ name: String, daysAgo: Double) -> FolderListing.Note {
            FolderListing.Note(url: URL(fileURLWithPath: "/n/\(name).md"), title: name, modified: now.addingTimeInterval(-daysAgo * 86_400))
        }
        let notes = [note("note 10", daysAgo: 2), note("beta", daysAgo: 0), note("note 9", daysAgo: 5), note("Alpha", daysAgo: 1)]
        func names(_ notes: [FolderListing.Note]) -> [String] { notes.map(\.title) }
        #expect(names(LibraryOrganize.sorted(notes, by: .modified)) == ["beta", "Alpha", "note 10", "note 9"])
        // Names in their natural order: 9 before 10, case aside.
        #expect(names(LibraryOrganize.sorted(notes, by: .name)) == ["Alpha", "beta", "note 9", "note 10"])
        // By creation; a note with no date read yet goes by its last change.
        let created: [URL: Date] = [
            URL(fileURLWithPath: "/n/note 9.md"): now,
            URL(fileURLWithPath: "/n/beta.md"): now.addingTimeInterval(-30 * 86_400),
        ]
        #expect(names(LibraryOrganize.sorted(notes, by: .created, created: created)) == ["note 9", "Alpha", "note 10", "beta"])
        #expect(LibrarySort(storage: "nonsense") == .modified)
    }

    @Test func sortOrdersTheNotesInsideEachGroup() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func note(_ name: String, hoursAgo: Double) -> FolderListing.Note {
            FolderListing.Note(url: URL(fileURLWithPath: "/n/\(name).md"), title: name, modified: now.addingTimeInterval(-hoursAgo * 3_600))
        }
        let notes = [note("cherry", hoursAgo: 1), note("apple", hoursAgo: 2), note("banana", hoursAgo: 30), note("avocado", hoursAgo: 31)]
        let byName = LibraryOrganize.sorted(notes, by: .name)
        let groups = LibraryOrganize.groups(byName, by: .modified, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Today", "Yesterday"])
        #expect(groups.map { $0.notes.map(\.title) } == [["apple", "cherry"], ["avocado", "banana"]])
    }

    @Test func notesGroupByTheDayTheyWereMade() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let old = FolderListing.Note(url: URL(fileURLWithPath: "/n/old.md"), title: "old", modified: now)
        let new = FolderListing.Note(url: URL(fileURLWithPath: "/n/new.md"), title: "new", modified: now)
        let created = [old.url: now.addingTimeInterval(-86_400)]
        let groups = LibraryOrganize.groups([old, new], by: .created, created: created, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Today", "Yesterday"])
        #expect(groups.last?.notes == [old])
        #expect(LibraryGrouping(storage: LibraryGrouping.created.storage) == .created)
    }

    @Test func creationDatesAreReadFromTheFiles() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("old.md")
        let made = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: made], ofItemAtPath: note.path)
        let dates = NoteDates.created([note, root.appendingPathComponent("missing.md")])
        #expect(dates.count == 1)
        #expect(abs((dates[note.standardizedFileURL] ?? .distantPast).timeIntervalSince(made)) < 1)
    }

    @Test func pinnedNotesLeaveTheRestAndAreNotRepeated() {
        func note(_ name: String) -> FolderListing.Note {
            FolderListing.Note(url: URL(fileURLWithPath: "/n/\(name).md"), title: name, modified: Date(timeIntervalSince1970: 0))
        }
        let notes = [note("a"), note("b"), note("c"), note("d")]
        // A pin elsewhere, in another folder, pins nothing here.
        let pins = Pins([URL(fileURLWithPath: "/n/c.md"), URL(fileURLWithPath: "/n/a.md"), URL(fileURLWithPath: "/other/b.md")])
        let split = LibraryOrganize.split(notes) { pins.contains($0) }
        // In the notes' order, not the order they were pinned in.
        #expect(split.pinned.map(\.title) == ["a", "c"])
        #expect(split.rest.map(\.title) == ["b", "d"])
        let none = LibraryOrganize.split(notes) { Pins().contains($0) }
        #expect(none.pinned.isEmpty)
        #expect(none.rest == notes)
    }

    @Test func frontmatterGivesTopLevelProperties() {
        let text = "---\ntitle: \"Hello\"\nstatus: draft # soon\ntags: [one, two]\naliases:\n  - first\n  - second\nnested:\n  key: x\n---\n# Body\nkey: not this"
        let values = NoteProperties.parse(text)
        #expect(values["title"] == "Hello")
        #expect(values["status"] == "draft")
        #expect(values["tags"] == "one")
        #expect(values["aliases"] == "first")
        #expect(values["nested"] == nil)
        #expect(values["key"] == nil)
        #expect(NoteProperties.parse("# No frontmatter\nstatus: x").isEmpty)
        #expect(NoteProperties.parse("---\nstatus: open").isEmpty)
        #expect(LibraryOrganize.groupableKeys([URL(fileURLWithPath: "/a"): ["title": "x", "status": "y"]]) == ["status"])
    }

    @Test func searchMatchesEveryWordInNameOrTitle() {
        #expect(LibraryOrganize.matches("", name: "anything.md"))
        #expect(LibraryOrganize.matches("renais", name: "renaissance-notes.md"))
        #expect(LibraryOrganize.matches("emile plan", name: "x.md", title: "Émile's Plan"))
        #expect(!LibraryOrganize.matches("emile budget", name: "x.md", title: "Émile's Plan"))
    }

    /// A theme names its library surfaces with `color.surface.*`; left
    /// out, they derive from its canvas.
    @Test func themeSurfacesAreNamedOrDerived() {
        let theme = Theme.user(named: "t", text: "color.canvas.dark = #15181C\ncolor.surface.card.dark = #1A1C1F\ncolor.surface.ground = #EEEEEE\n")
        let surfaces = Appearance.surfaceHexes(theme.palette)
        #expect(surfaces.card.dark == "#1A1C1F")
        #expect(surfaces.ground.light == "#EEEEEE")
        #expect(surfaces.ground.dark == "#15181C")
        #expect(surfaces.card.light == theme.palette.canvas)
        #expect(surfaces.border.dark == HexColor.blend("#FFFFFF", over: "#15181C", alpha: 0.12))
        #expect(theme.palette.overrides.fileText.contains("color.surface.card.dark = #1A1C1F"))
    }

    private static func samples(_ rep: NSBitmapImageRep) -> [Double] {
        var values: [Double] = []
        let step = 6
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                values.append(Double(color.redComponent + color.greenComponent + color.blueComponent) / 3)
            }
        }
        return values
    }

    private static func meanBrightness(_ rep: NSBitmapImageRep) -> Double {
        let values = samples(rep)
        return values.reduce(0, +) / Double(max(values.count, 1))
    }

    /// What a library window does with cards dropped on it from another
    /// library window: the files move into the folder it shows.
    @Test func aDropFromAnotherLibraryMovesTheFiles() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("old.md")
        let other = root.appendingPathComponent("alpha", isDirectory: true)
        await withCheckedContinuation { done in
            let took = LibraryDrag.shared.drop([note], into: other) { done.resume() }
            if !took { done.resume() }
        }
        #expect(!FileManager.default.fileExists(atPath: note.path))
        #expect(FileManager.default.fileExists(atPath: other.appendingPathComponent("old.md").path))
        // Dropped on the window it came from: nothing to move.
        #expect(!LibraryDrag.shared.drop([other.appendingPathComponent("old.md")], into: other))
    }

    /// Cards are handed to the system once the pointer is over anything
    /// but their own window: past its edge, or on a window over it.
    @Test func cardsLeaveTheirWindowWithThePointer() {
        #expect(!LibraryDrag.left(own: 12, under: 12))
        #expect(LibraryDrag.left(own: 12, under: 31))
        #expect(LibraryDrag.left(own: 12, under: 0))
    }

    // MARK: Pictures and videos (.plan/library-media.md)

    @Test func filesAreToldApartByKind() {
        func kind(_ name: String) -> LibraryKind? { LibraryKind.of(URL(fileURLWithPath: "/tmp/\(name)")) }
        #expect(kind("a.md") == .note)
        #expect(kind("a.txt") == .note)
        #expect(kind("a.png") == .image)
        #expect(kind("a.JPG") == .image)
        #expect(kind("a.svg") == .image)
        #expect(kind("a.heic") == .image)
        #expect(kind("a.mp4") == .video)
        #expect(kind("a.mov") == .video)
        #expect(kind("a.mp3") == .audio)
        #expect(kind("a.wav") == .audio)
        #expect(kind("a.pdf") == nil)
        #expect(kind("Makefile") == nil)
    }

    /// Pictures and videos join the notes, newest first; hidden ones only
    /// when hidden items show, and then marked; folder counts take them in.
    @Test func aFolderListsItsPicturesAndVideosAmongTheNotes() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let picture = root.appendingPathComponent("shot.png")
        let video = root.appendingPathComponent("clip.mp4")
        let secret = root.appendingPathComponent(".secret.png")
        let song = root.appendingPathComponent("song.mp3")
        for url in [picture, video, secret, song, root.appendingPathComponent("alpha/inside.jpg")] {
            try Data([0]).write(to: url)
        }
        try manager.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: video.path)

        let base = FolderListing.load(root, isDefaultRoot: false)
        let listed = FolderListing.addingMedia(to: base, hidden: [], in: root, includingHidden: false)
        let urls = listed.listing.notes.map(\.url.lastPathComponent)
        #expect(urls.contains("shot.png"))
        #expect(urls.first == "clip.mp4")
        #expect(urls.contains("song.mp3"))
        #expect(!urls.contains(".secret.png"))
        #expect(listed.hidden.isEmpty)
        let alpha = try #require(listed.listing.folders.first { $0.name == "alpha" })
        let before = try #require(base.folders.first { $0.name == "alpha" })
        #expect(alpha.itemCount == before.itemCount + 1)

        let all = FolderListing.loadIncludingHidden(root)
        let withHidden = FolderListing.addingMedia(to: all.listing, hidden: all.hidden, in: root, includingHidden: true)
        #expect(withHidden.listing.notes.contains { $0.url.lastPathComponent == ".secret.png" })
        #expect(withHidden.hidden.contains { $0.lastPathComponent == ".secret.png" })
    }

    @Test func theFilterKeepsOneKind() {
        let urls = ["a.md", "b.png", "c.mp4", "d.mp3"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        func kept(_ filter: LibraryFilter) -> [String] { urls.filter(filter.admits).map(\.lastPathComponent) }
        #expect(kept(.all) == ["a.md", "b.png", "c.mp4", "d.mp3"])
        #expect(kept(.notes) == ["a.md"])
        #expect(kept(.images) == ["b.png"])
        #expect(kept(.videos) == ["c.mp4"])
        #expect(kept(.audio) == ["d.mp3"])
        #expect(LibraryFilter(storage: "bogus") == .all)
    }

    @Test func notesGroupByKind() {
        let now = Date()
        let notes = ["clip.mp4", "a.md", "shot.png", "b.md"].enumerated().map { index, name in
            FolderListing.Note(url: URL(fileURLWithPath: "/tmp/\(name)"), title: name, modified: now.addingTimeInterval(-Double(index)))
        }
        let groups = LibraryOrganize.groups(notes, by: .kind)
        #expect(groups.map(\.title) == ["Notes", "Images", "Videos"])
        #expect(groups[0].notes.map(\.title) == ["a.md", "b.md"])
        #expect(LibraryGrouping(storage: LibraryGrouping.kind.storage) == .kind)
    }

    @Test func videoLengthsReadAsAClock() {
        #expect(MediaPicture.format(seconds: 35.4) == "0:35")
        #expect(MediaPicture.format(seconds: 65) == "1:05")
        #expect(MediaPicture.format(seconds: 3725) == "1:02:05")
    }

    /// A paste copies: the original stays, and a taken name is numbered.
    @Test func pastedFilesAreCopiedAndNumbered() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("old.md")
        let copies = LibraryDrag.copy([note], into: root)
        #expect(copies.map(\.lastPathComponent) == ["old 2.md"])
        #expect(FileManager.default.fileExists(atPath: note.path))
        let inAlpha = LibraryDrag.copy([note], into: root.appendingPathComponent("alpha"))
        #expect(inAlpha.map(\.lastPathComponent) == ["old.md"])
    }

    @Test func movesSkipTheirOwnFolderAndFoldersIntoThemselves() {
        let root = URL(fileURLWithPath: "/tmp/library")
        let note = root.appendingPathComponent("a.md")
        let folder = root.appendingPathComponent("Inbox", isDirectory: true)
        let inner = folder.appendingPathComponent("Deep", isDirectory: true)
        // Into the folder it is already in: nothing, not "a 2.md".
        #expect(LibraryDrag.movable([note, folder], into: root).isEmpty)
        // A folder not into itself or below itself; a note into it is fine.
        #expect(LibraryDrag.movable([note, folder], into: folder) == [note])
        #expect(LibraryDrag.movable([folder], into: inner).isEmpty)
        #expect(LibraryDrag.movable([inner], into: root) == [inner])
    }

    private static func distinctBrightness(_ rep: NSBitmapImageRep) -> Int {
        Set(samples(rep).map { Int($0 * 255) }).count
    }

    /// A mouse wheel eases as Canvas's does: 27 points a line, five lines
    /// an event at most, and 63% of the way in each 60 ms.
    @Test
    func aWheelStepEasesTowardItsTarget() {
        #expect(LibraryWheel.travel(lines: 1) == 27)
        #expect(LibraryWheel.travel(lines: -3) == -81)
        #expect(LibraryWheel.travel(lines: 20) == 135)
        #expect(LibraryWheel.share(after: 0) == 0)
        #expect(abs(LibraryWheel.share(after: 0.06) - 0.632) < 0.001)
        // Two half steps cover what one whole step does.
        let half = LibraryWheel.share(after: 0.004)
        #expect(abs((1 - (1 - half) * (1 - half)) - LibraryWheel.share(after: 0.008)) < 1e-9)
    }

    /// The picture grid's arithmetic: tiles of 120 points or more fill
    /// the row, and a point finds its tile or a gap.
    @Test
    func thePictureGridPlacesItsTiles() {
        let grid = MediaGridLayout(width: 612, count: 23)
        #expect(grid.columns == 5)
        #expect(grid.side == 120)
        #expect(grid.rows == 5)
        #expect(abs(grid.height - 612) < 0.001)
        #expect(grid.rect(6) == CGRect(x: 123, y: 123, width: 120, height: 120))
        #expect(grid.index(at: CGPoint(x: 130, y: 130)) == 6)
        #expect(grid.index(at: CGPoint(x: 121, y: 130)) == nil, "the gap between two tiles")
        #expect(grid.index(at: CGPoint(x: 500, y: 500)) == nil, "past the last tile")
        #expect(grid.indices(in: CGRect(x: 0, y: 130, width: 612, height: 10)) == 5..<10)
        #expect(grid.indices(in: CGRect(x: 0, y: 400, width: 612, height: 900)) == 15..<23)
        #expect(grid.indices(in: CGRect(x: 0, y: 2000, width: 612, height: 10)).isEmpty)
        // A wide page with few tiles: they stop at 180 and keep to the left.
        #expect(MediaGridLayout(width: 190, count: 1).side == 180)
        #expect(MediaGridLayout(width: 0, count: 0).height == 0)
    }

    /// Agent apps are told the cards in view, with any picked or under
    /// the pointer; all of them when no card's place is known.
    @Test
    func theContextListsWhatIsInView() {
        let urls = (1...6).map { URL(fileURLWithPath: "/tmp/\($0).png") }
        let seen = LibraryContextTree.inView(urls, selection: [urls[4]], hovered: urls[5]) { $0 == urls[0] || $0 == urls[1] }
        #expect(seen == [urls[0], urls[1], urls[4], urls[5]])
        #expect(LibraryContextTree.inView(urls, selection: [urls[4]], hovered: nil) { _ in false } == nil)
    }
}
