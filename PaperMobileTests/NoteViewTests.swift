import Testing
import SwiftUI
import UIKit
@testable import Paper

@MainActor
struct NoteViewTests {
    /// The note screen loads its file into the editor.
    @Test func aNoteOpensInTheEditor() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe.md")
        try "# Hello\n\nBody text".write(to: url, atomically: true, encoding: .utf8)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let host = UIHostingController(rootView: NavigationStack { NoteView(url: url) })
        window.rootViewController = host
        window.makeKeyAndVisible()
        func find(_ v: UIView) -> MobileTextView? {
            if let t = v as? MobileTextView { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        // The file loads in the view's task; wait for the editor to appear.
        var tv: MobileTextView?
        for _ in 0..<50 where tv == nil {
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            tv = find(host.view)
        }
        let textView = try #require(tv)
        #expect(textView.text == "# Hello\n\nBody text")
        #expect(textView.isEditable)
        #expect(textView.frame.height > 0)
        window.isHidden = true
    }
}

@MainActor
struct NewNoteTests {
    @Test func anEmptyNoteOpensOnATitleLine() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("empty.md")
        try "".write(to: url, atomically: true, encoding: .utf8)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let host = UIHostingController(rootView: NavigationStack { NoteView(url: url) })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func find(_ v: UIView) -> MobileTextView? {
            if let t = v as? MobileTextView { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        var tv: MobileTextView?
        for _ in 0..<50 where tv?.isFirstResponder != true {
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            tv = find(host.view)
        }
        let textView = try #require(tv)
        #expect(textView.text == "# ")
        #expect(textView.selectedRange == NSRange(location: 2, length: 0))
        #expect(textView.isFirstResponder)
        // The caret stands at the heading's size, not the body's.
        let position = try #require(textView.position(from: textView.beginningOfDocument, offset: 2))
        #expect(textView.caretRect(for: position).height > Appearance.bodyFont().lineHeight + 4)
        // Untouched, the file stays empty.
        #expect(try String(contentsOf: url, encoding: .utf8) == "")
    }
}

struct LibrarySearchTests {
    @Test func searchFindsNotesByTitleAndTextInSubfolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("journal")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Grocery list\n\n- milk\n".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "# Monday\n\nBought milk on the way home.\n".write(to: nested.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try "# Other\n\nNothing here.\n".write(to: nested.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)
        #expect(Set(FolderListing.search("MILK", under: root, isDefaultRoot: false).map(\.title)) == ["Grocery list", "Monday"])
        #expect(FolderListing.search("grocery", under: root, isDefaultRoot: false).map(\.title) == ["Grocery list"])
        #expect(FolderListing.search("absent", under: root, isDefaultRoot: false).isEmpty)
    }
}

@MainActor
struct ZoomDismissTests {
    private struct Harness: View {
        let url: URL
        @Namespace var cards
        @State var path: [URL] = []
        var body: some View {
            NavigationStack(path: $path) {
                Button("Open") { path = [url] }
                    .matchedTransitionSource(id: url, in: cards)
                    .navigationDestination(for: URL.self) { url in
                        NoteView(url: url).navigationTransition(.zoom(sourceID: url, in: cards))
                    }
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { path = [url] } }
            }
        }
    }

    /// A pull down must not close a note; only the sideways swipe does.
    @Test func aNoteOpenedWithTheZoomIgnoresAPullDown() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zoom.md")
        try "# Hi\n\nBody".write(to: url, atomically: true, encoding: .utf8)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: Harness(url: url))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(100)); window.layoutIfNeeded() }
        var recognizers: [UIGestureRecognizer] = []
        func walk(_ v: UIView) { recognizers += v.gestureRecognizers ?? []; v.subviews.forEach(walk) }
        walk(window)
        let pullDown = recognizers.filter { $0.name?.contains("ZoomInteractiveDismissSwipeDown") == true }
        try #require(!pullDown.isEmpty)
        #expect(pullDown.allSatisfy { !$0.isEnabled })
        #expect(recognizers.contains { $0.name == "UINavigationController.edgeSwipe" && $0.isEnabled })
    }
}

struct LibraryFileTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("themes"), withIntermediateDirectories: true)
        return root
    }

    @Test func movingANoteNumbersItWhenTheNameIsTaken() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("a")
        try "one".write(to: root.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)
        try "taken".write(to: target.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)
        try NoteFile.move(root.appendingPathComponent("n.md"), into: target)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("n.md").path))
        #expect(try String(contentsOf: target.appendingPathComponent("n 2.md"), encoding: .utf8) == "one")
    }

    @Test func deletingANoteRemovesIt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("gone.md")
        try "x".write(to: note, atomically: true, encoding: .utf8)
        try NoteFile.delete(note)
        #expect(!FileManager.default.fileExists(atPath: note.path))
    }

    @Test func everyFolderIsListedExceptPapersOwnAtTheDefaultRoot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = FolderListing.allFolders(under: root, isDefaultRoot: true).map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
        #expect(names == ["a", "a/b"])
    }
}
