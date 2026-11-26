import AppKit
import Quartz
import SwiftUI

/// A folder opened in Paper: one window per folder, showing its folders and
/// notes as cards, as the iPhone library does. Opening a folder that is
/// already open brings its window forward. Notes open in their own
/// document windows; the library stays where it is.
@MainActor
enum LibraryWindow {
    private static var windows: [URL: NSWindow] = [:]
    private static var navigations: [URL: LibraryNavigation] = [:]
    private static var delegates: [URL: Closer] = [:]
    private static var toolbars: [URL: LibraryToolbar] = [:]

    static let minimumSize = NSSize(width: 600, height: 420)

    static func open(_ folder: URL) {
        let folder = folder.standardizedFileURL
        LibraryOpening.noteRecent(folder)
        // Opening a folder answers the welcome window, as a document does.
        WelcomeWindow.close()
        if let window = windows[folder] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let configuration = ConfigurationStore.shared.current
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: configuration.windowWidth, height: configuration.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        LibraryWheel.install(isLibrary: isLibraryWindow)
        let navigation = LibraryNavigation(root: folder)
        navigation.window = window
        navigations[folder] = navigation
        let hosting = NSHostingView(rootView: LibraryView(navigation: navigation))
        // The hosting view would otherwise set the window's smallest size
        // from the page's, which shrinks to one card: the window's own
        // minimum, wide enough for the toolbar's title and controls beside
        // the traffic lights, would not hold.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.applyPaperChrome(minSize: Self.minimumSize)
        window.contentMinSize = Self.minimumSize
        // A drag on the grid draws the selection rectangle; only the
        // toolbar moves the window.
        window.isMovableByWindowBackground = false
        // Finder's back and forward, then the folder's name, in the bar.
        toolbars[folder] = LibraryToolbar(navigation: navigation, window: window)
        window.tabbingMode = .disallowed
        // Each folder keeps the size and place it was last given.
        if !window.setFrameUsingName(frameName(folder)) { window.centerExactly() }
        // A frame saved narrower than the minimum is brought up to it.
        if window.frame.width < Self.minimumSize.width || window.frame.height < Self.minimumSize.height {
            var frame = window.frame
            frame.size.width = max(frame.width, Self.minimumSize.width)
            let height = max(frame.height, Self.minimumSize.height)
            frame.origin.y -= height - frame.height
            frame.size.height = height
            window.setFrame(frame, display: false)
        }
        window.setFrameAutosaveName(frameName(folder))
        let closer = Closer(folder: folder)
        window.delegate = closer
        delegates[folder] = closer
        windows[folder] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The open libraries, for agent apps: each with its window.
    static func openLibraries() -> [LibraryNavigation] {
        Array(navigations.values)
    }

    /// Whether a window is one of the library's.
    private static func isLibraryWindow(_ window: NSWindow) -> Bool {
        windows.values.contains { $0 === window }
    }

    /// Note windows opened over a library in full screen, set to float in
    /// its space rather than take a full screen of their own.
    /// Held weakly: a note closed while floating is let go.
    private static let floating = NSHashTable<NSWindow>.weakObjects()
    private static var exitObserver: NSObjectProtocol?

    /// Whether a library is in full screen on the space in front.
    static var isFullScreenOnActiveSpace: Bool {
        windows.values.contains { $0.styleMask.contains(.fullScreen) && $0.isOnActiveSpace }
    }

    /// Sets a note's window, before it shows, to float in a full-screen
    /// library's space rather than take a full screen of its own: notes
    /// are rarely wanted full screen, and this keeps the library in view.
    /// Once the library leaves full screen, the window can go full screen
    /// again like any other.
    static func float(_ window: NSWindow) {
        guard !isLibraryWindow(window) else { return }
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        floating.add(window)
        guard exitObserver == nil else { return }
        exitObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main
        ) { note in
            let number = (note.object as? NSWindow)?.windowNumber
            MainActor.assumeIsolated {
                guard let number, let library = NSApp.window(withWindowNumber: number), isLibraryWindow(library) else { return }
                unfloatIfNoFullScreen()
            }
        }
    }

    /// Once no library is in full screen, floated notes may take a full
    /// screen of their own again.
    private static func unfloatIfNoFullScreen() {
        guard !windows.values.contains(where: { $0.styleMask.contains(.fullScreen) }) else { return }
        for window in floating.allObjects {
            window.collectionBehavior.remove(.fullScreenAuxiliary)
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
        floating.removeAllObjects()
    }

    private static func frameName(_ folder: URL) -> String { "Library \(folder.path)" }

    fileprivate static func closed(_ folder: URL) {
        windows[folder] = nil
        navigations[folder] = nil
        delegates[folder] = nil
        toolbars[folder]?.stop()
        toolbars[folder] = nil
        // A library closed while in full screen never reports leaving it.
        unfloatIfNoFullScreen()
    }

    private final class Closer: NSObject, NSWindowDelegate {
        let folder: URL
        init(folder: URL) { self.folder = folder }

        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { LibraryWindow.closed(folder) }
        }

        // The Quick Look panel, open over a library, is the library's: it
        // steps through the folder's pictures and videos.
        override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

        override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
            MainActor.assumeIsolated { LibraryPreview.shared.begin(panel) }
        }

        override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
            MainActor.assumeIsolated { LibraryPreview.shared.end(panel) }
        }
    }
}
