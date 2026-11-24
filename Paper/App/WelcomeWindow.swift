import AppKit
import SwiftUI

/// The window shown when the app has nothing to open: on launch without a
/// document, and on a Dock click while no window is open. One instance,
/// sized like a document window. It closes once a document window becomes
/// key, so a cancelled Open panel or a dismissed Settings leaves it up.
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?
    private static var observer: NSObjectProtocol?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let recents = WelcomeModel.recents(from: NSDocumentController.shared.recentDocumentURLs)
        let folders = WelcomeModel.recents(from: LibraryOpening.recentFolders)
        let view = WelcomeView(recents: recents, folders: folders, greeting: WelcomeModel.greeting)
        let configuration = ConfigurationStore.shared.current
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: configuration.windowWidth, height: configuration.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.applyPaperChrome(minSize: NSSize(width: 640, height: 520))
        window.title = "Welcome"
        window.centerExactly()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { notification in
            guard let key = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                if isDocumentWindow(key) { close() }
            }
        }
    }

    private static func isDocumentWindow(_ window: NSWindow) -> Bool {
        NSDocumentController.shared.documents.contains { document in
            document.windowControllers.contains { $0.window == window }
        }
    }

    static func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        window?.close()
        window = nil
    }
}
