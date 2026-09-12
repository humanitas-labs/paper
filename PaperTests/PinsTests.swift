import Foundation
import Testing
@testable import Paper

struct PinsTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func toggleAppendsThenRemovesAndKeepsOrder() {
        var pins = Pins()
        pins.toggle(url("/tmp/a.md"))
        pins.toggle(url("/tmp/b.md"))
        pins.toggle(url("/tmp/c.md"))
        #expect(pins.urls.map(\.lastPathComponent) == ["a.md", "b.md", "c.md"])
        pins.toggle(url("/tmp/b.md"))
        #expect(pins.urls.map(\.lastPathComponent) == ["a.md", "c.md"])
        #expect(!pins.contains(url("/tmp/b.md")))
    }

    @Test func pathsAreStandardizedAndNotDuplicated() {
        var pins = Pins()
        pins.toggle(url("/tmp/notes/../a.md"))
        #expect(pins.contains(url("/tmp/a.md")))
        pins.toggle(url("/tmp/./a.md"))
        #expect(pins.urls.isEmpty)
        #expect(Pins([url("/tmp/a.md"), url("/tmp/a.md")]).urls.count == 1)
    }

    @Test func encodesAndDecodesInOrder() {
        let pins = Pins([url("/tmp/b.md"), url("/tmp/a.md")])
        let text = String(decoding: pins.encoded(), as: UTF8.self)
        #expect(text.contains("\"pins\""))
        #expect(Pins.decode(pins.encoded()) == pins)
    }

    @Test func badDataIsNoPins() {
        #expect(Pins.decode(Data()) == Pins())
        #expect(Pins.decode(Data("not json".utf8)) == Pins())
        #expect(Pins.decode(Data("{\"pins\": \"nope\"}".utf8)) == Pins())
        #expect(Pins.decode(Data("[]".utf8)) == Pins())
    }

    @Test func moveReorders() {
        var pins = Pins([url("/tmp/a.md"), url("/tmp/b.md"), url("/tmp/c.md")])
        pins.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(pins.urls.map(\.lastPathComponent) == ["c.md", "a.md", "b.md"])
    }

    @Test func menuEntriesFlagMissingFilesInPlace() {
        let pins = Pins([url("/tmp/a.md"), url("/tmp/gone.md"), url("/tmp/b.md")])
        let entries = MenuBarModel.pinned(pins) { $0.lastPathComponent != "gone.md" }
        #expect(entries.map(\.name) == ["a.md", "gone.md", "b.md"])
        #expect(entries.map(\.missing) == [false, true, false])
    }

    @Test @MainActor func storeWritesAndAFreshStoreReadsBack() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paper-pins-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Paper/state.json")

        let store = PinStore(fileURL: file)
        store.start()
        #expect(store.pins == Pins())
        store.toggle(url("/tmp/a.md"))
        store.toggle(url("/tmp/b.md"))
        store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(FileManager.default.fileExists(atPath: file.path))

        let again = PinStore(fileURL: file)
        again.start()
        #expect(again.pins.urls.map(\.lastPathComponent) == ["b.md", "a.md"])
        again.remove(url("/tmp/b.md"))
        let third = PinStore(fileURL: file)
        third.start()
        #expect(third.pins.urls.map(\.lastPathComponent) == ["a.md"])
    }
}

struct PinNameTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func aNameShowsInPlaceOfTheFileNameAndBlankClearsIt() {
        var pins = Pins([url("/tmp/wm-session.md"), url("/tmp/b.md")])
        pins.rename(url("/tmp/wm-session.md"), to: "  Session plan ")
        #expect(pins.pin(for: url("/tmp/wm-session.md"))?.name == "Session plan")
        #expect(MenuBarModel.pinned(pins) { _ in true }.map(\.name) == ["Session plan", "b.md"])
        pins.rename(url("/tmp/wm-session.md"), to: "   ")
        #expect(pins.pin(for: url("/tmp/wm-session.md"))?.name == nil)
        pins.rename(url("/tmp/not-pinned.md"), to: "x")
        #expect(pins.urls.count == 2, "naming an unpinned file pins nothing")
    }

    @Test func namesRoundTripAndTheOldBarePathFormStillReads() {
        var pins = Pins([url("/tmp/a.md"), url("/tmp/b.md")])
        pins.rename(url("/tmp/a.md"), to: "Today")
        #expect(Pins.decode(pins.encoded()) == pins)
        let old = Pins.decode(Data("{\"pins\": [\"/tmp/a.md\", {\"path\": \"/tmp/b.md\", \"name\": \"Plan\"}, 7]}".utf8))
        #expect(old.urls.map(\.lastPathComponent) == ["a.md", "b.md"])
        #expect(old.pin(for: url("/tmp/b.md"))?.name == "Plan")
    }
}
