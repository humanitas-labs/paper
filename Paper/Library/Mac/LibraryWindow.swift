import AppKit
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
        let navigation = LibraryNavigation(root: folder)
        navigation.window = window
        navigations[folder] = navigation
        window.contentView = NSHostingView(rootView: LibraryView(navigation: navigation))
        window.isReleasedWhenClosed = false
        window.applyPaperChrome(minSize: NSSize(width: 520, height: 420))
        // A drag on the grid draws the selection rectangle; only the
        // toolbar moves the window.
        window.isMovableByWindowBackground = false
        // Finder's back and forward, then the folder's name, in the bar.
        toolbars[folder] = LibraryToolbar(navigation: navigation, window: window)
        window.tabbingMode = .disallowed
        // Each folder keeps the size and place it was last given.
        if !window.setFrameUsingName(frameName(folder)) { window.centerExactly() }
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

    /// Whether a window is one of the library's, so other window rules
    /// (the welcome window's, new-window placement) can leave it alone.
    static func isLibraryWindow(_ window: NSWindow) -> Bool {
        windows.values.contains { $0 === window }
    }

    /// Note windows opened over a library in full screen, set to float in
    /// its space rather than take a full screen of their own.
    private static var floating: [ObjectIdentifier: NSWindow] = [:]
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
        floating[ObjectIdentifier(window)] = window
        guard exitObserver == nil else { return }
        exitObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main
        ) { note in
            let number = (note.object as? NSWindow)?.windowNumber
            MainActor.assumeIsolated {
                guard let number, let library = NSApp.window(withWindowNumber: number), isLibraryWindow(library),
                      !windows.values.contains(where: { $0.styleMask.contains(.fullScreen) }) else { return }
                for window in floating.values {
                    window.collectionBehavior.remove(.fullScreenAuxiliary)
                    window.collectionBehavior.insert(.fullScreenPrimary)
                }
                floating.removeAll()
            }
        }
    }

    private static func frameName(_ folder: URL) -> String { "Library \(folder.path)" }

    fileprivate static func closed(_ folder: URL) {
        windows[folder] = nil
        navigations[folder] = nil
        delegates[folder] = nil
        toolbars[folder]?.stop()
        toolbars[folder] = nil
    }

    private final class Closer: NSObject, NSWindowDelegate {
        let folder: URL
        init(folder: URL) { self.folder = folder }

        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { LibraryWindow.closed(folder) }
        }
    }
}
