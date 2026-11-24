import AppKit
import SwiftUI

/// Dropping files dragged in from Finder: onto a folder card they move
/// into that folder, onto the page into the folder shown. Cards dragged
/// within the library are carried by the library itself (`CarriedCards`),
/// so the card itself lifts out of the grid rather than a picture of it.
@MainActor
final class LibraryDrag {
    static let shared = LibraryDrag()
    /// Where each tab is in the window, so a carried card can be
    /// dropped on one.
    var tabFrames: [UUID: CGRect] = [:]

    /// The items that can go into `folder`: not the folder itself or one
    /// above it, and not one already there.
    static func movable(_ urls: [URL], into folder: URL) -> [URL] {
        let destination = folder.standardizedFileURL.path
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            let parent = url.standardizedFileURL.deletingLastPathComponent().path
            return path != destination && !destination.hasPrefix(path + "/") && parent != destination
        }
    }

    /// Moves what was dropped into `folder`, off the main thread, as the
    /// toast's Move does; then `done`. False when nothing could go.
    @discardableResult
    func drop(_ dropped: [URL], into folder: URL, done: @escaping @MainActor () -> Void = {}) -> Bool {
        let moving = Self.movable(dropped.filter(\.isFileURL), into: folder)
        guard !moving.isEmpty else { return false }
        Task {
            await Task.detached { for url in moving { try? NoteFile.move(url, into: folder) } }.value
            done()
        }
        return true
    }
}

/// A folder that takes drops: it lights while a drag is over it, and
/// what is dropped moves into it.
struct FolderDrop: ViewModifier {
    let folder: URL
    @Binding var targeted: Bool
    var done: @MainActor () -> Void = {}

    func body(content: Content) -> some View {
        content.dropDestination(for: URL.self) { dropped, _ in
            LibraryDrag.shared.drop(dropped, into: folder, done: done)
        } isTargeted: { over in
            withAnimation(.spring(duration: 0.22, bounce: 0.2)) { targeted = over }
        }
    }
}

/// Cards lifted out of the grid by a drag.
struct CarriedCards {
    /// The grabbed card first.
    var urls: [URL]
    var sizes: [URL: CGSize]
    /// Where the pointer took hold, from the grabbed card's center.
    var grab: CGSize
    /// The pointer, in the window's content.
    var point: CGPoint
    /// Where they are sinking to once let go over a folder or a tab.
    var sinking: CGPoint?
}
