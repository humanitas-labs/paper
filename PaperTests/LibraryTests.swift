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

    private static func distinctBrightness(_ rep: NSBitmapImageRep) -> Int {
        Set(samples(rep).map { Int($0 * 255) }).count
    }
}
