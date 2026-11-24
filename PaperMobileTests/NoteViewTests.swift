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
