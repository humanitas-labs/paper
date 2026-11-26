import AppKit
import SwiftUI

/// Dropping files dragged in from Finder or from another library window:
/// onto a folder card or a tab they move into that folder, onto the page
/// into the folder shown. Cards dragged within the library are carried by
/// the library itself (`CarriedCards`), so the card itself lifts out of
/// the grid rather than a picture of it; carried out of the window, they
/// are handed to the system as a drag of their files.
@MainActor
final class LibraryDrag {
    static let shared = LibraryDrag()
    /// Where each tab is in the window, so a carried card can be
    /// dropped on one.
    var tabFrames: [UUID: CGRect] = [:]
    /// The drags out of a window still in the air, kept until they end.
    fileprivate var sources: Set<LibraryDragSource> = []

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

    /// Copies files into `folder`, as a paste does: a name already taken
    /// there is numbered, and nothing is replaced. Returns the copies.
    @discardableResult
    nonisolated static func copy(_ urls: [URL], into folder: URL) -> [URL] {
        var copies: [URL] = []
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let base = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
            let target = LibraryNames.unused(base, extension: isFolder ? "" : url.pathExtension, in: folder)
            if (try? FileManager.default.copyItem(at: url, to: target)) != nil { copies.append(target) }
        }
        return copies
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

// MARK: Out of the window

extension LibraryDrag {
    /// Whether the pointer has left `window`: it is past the window's
    /// edge, or over another window lying on top of it.
    static func pointerLeft(_ window: NSWindow) -> Bool {
        left(own: window.windowNumber, under: NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0))
    }

    /// `under` is the window the pointer is over, 0 over none.
    static func left(own: Int, under: Int) -> Bool { under != own }

    /// Hands carried cards to the system as a drag of their files, begun
    /// from the mouse drag in progress, so they can be dropped on another
    /// library window, on Finder or on another app. The cards' pictures
    /// go with the pointer as they were held. False when no drag could
    /// begin; `ended` once the drag is over, taken or not.
    func handOff(
        _ carried: CarriedCards, pictures: [URL: NSImage], from window: NSWindow, ended: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let view = window.contentView, let event = NSApp.currentEvent, event.type == .leftMouseDragged else { return false }
        let pointer = view.convert(event.locationInWindow, from: nil)
        let down: CGFloat = view.isFlipped ? 1 : -1
        let items = carried.urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let size = carried.sizes[url] ?? CGSize(width: 150, height: 200)
            let fan = CGFloat(min(index, 3)) * 4
            let center = CGPoint(
                x: pointer.x - carried.grab.width + fan,
                y: pointer.y - (carried.grab.height - fan) * down
            )
            item.setDraggingFrame(
                CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                contents: pictures[url]
            )
            return item
        }
        guard !items.isEmpty else { return false }
        let source = LibraryDragSource(ended: ended)
        let session = view.beginDraggingSession(with: items, event: event, source: source)
        // Not taken: the pictures fly back to where the cards are.
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        sources.insert(source)
        source.release = { [weak self, weak source] in
            if let source { self?.sources.remove(source) }
        }
        return true
    }
}

/// The source of a drag of cards out of their window. A library that
/// takes the drop moves the files itself; Finder and other apps may move
/// or copy them.
@MainActor
final class LibraryDragSource: NSObject, NSDraggingSource {
    private let ended: @MainActor () -> Void
    var release: () -> Void = {}

    init(ended: @escaping @MainActor () -> Void) {
        self.ended = ended
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.move, .copy]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        ended()
        release()
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
