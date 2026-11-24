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
