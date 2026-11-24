import AppKit
import SwiftUI

/// A folder opened in Paper: one window per folder, showing its folders and
/// notes as cards, as the iPhone library does. Opening a folder that is
/// already open brings its window forward. Notes open in their own
/// document windows; the library stays where it is.
@MainActor
enum LibraryWindow {
    private static var windows: [URL: NSWindow] = [:]
    private static var delegates: [URL: Closer] = [:]

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
        window.contentView = NSHostingView(rootView: LibraryView(root: folder))
        window.isReleasedWhenClosed = false
        window.applyPaperChrome(minSize: NSSize(width: 520, height: 420))
        window.title = folder.lastPathComponent
        window.representedURL = folder
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
        #if DEBUG
        snapshotForDebugging(window)
        #endif
    }

    #if DEBUG
    /// DEBUG-SNAPSHOT (temporary): draws the library offscreen to PNGs,
    /// light and dark, where screen capture is not permitted.
    private static func snapshotForDebugging(_ window: NSWindow) {
        guard let dir = ProcessInfo.processInfo.environment["PAPER_LIBRARY_SNAPSHOT"],
              let folder = window.representedURL else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let listing = FolderListing.load(folder, isDefaultRoot: false)
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                appearance.performAsCurrentDrawingAppearance {
                    for note in listing.notes {
                        _ = NoteMiniature.image(
                            for: note.url, modified: note.modified, dark: dark,
                            background: NSColor(LibraryPalette.card)
                        )
                    }
                    let view = LibraryView(root: folder, listing: listing, scrolls: false)
                        .frame(width: 1280, height: 820)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    guard let image = renderer.cgImage else { return }
                    let url = URL(fileURLWithPath: dir).appendingPathComponent(dark ? "library-dark.png" : "library-light.png")
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
    }
    #endif

    /// Whether a window is one of the library's, so other window rules
    /// (the welcome window's, new-window placement) can leave it alone.
    static func isLibraryWindow(_ window: NSWindow) -> Bool {
        windows.values.contains { $0 === window }
    }

    private static func frameName(_ folder: URL) -> String { "Library \(folder.path)" }

    fileprivate static func closed(_ folder: URL) {
        windows[folder] = nil
        delegates[folder] = nil
    }

    private final class Closer: NSObject, NSWindowDelegate {
        let folder: URL
        init(folder: URL) { self.folder = folder }

        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { LibraryWindow.closed(folder) }
        }
    }
}
