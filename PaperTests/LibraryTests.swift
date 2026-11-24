import AppKit
import Foundation
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
