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
        #if DEBUG
        snapshotForDebugging(window)
        dumpFullScreenForDebugging(window)
        #endif
    }

    #if DEBUG
    /// DEBUG-SNAPSHOT (temporary): enters full screen and writes the
    /// windows' view trees to a file.
    private static func dumpFullScreenForDebugging(_ window: NSWindow) {
        guard let path = ProcessInfo.processInfo.environment["PAPER_LIBRARY_FSDUMP"] else { return }
        let windowed = ProcessInfo.processInfo.environment["PAPER_LIBRARY_WINDOWED"] != nil
        if !windowed { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { window.toggleFullScreen(nil) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.6) {
            func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
            if let content = window.contentView, let scroll = all(content).compactMap({ $0 as? NSScrollView }).first {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            var out = ""
            func walk(_ view: NSView, _ depth: Int) {
                var line = String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame) hidden=\(view.isHidden)"
                if let effect = view as? NSVisualEffectView { line += " material=\(effect.material.rawValue) state=\(effect.state.rawValue)" }
                if let color = view.layer?.backgroundColor { line += " bg=\(color.components ?? [])" }
                out += line + "\n"
                if depth < 9 { view.subviews.forEach { walk($0, depth + 1) } }
            }
            for other in NSApp.windows {
                out += "WINDOW \(type(of: other)) \(other.frame) visible=\(other.isVisible) bg=\(other.backgroundColor.description) opaque=\(other.isOpaque)\n"
                if let frame = other.contentView?.superview { walk(frame, 1) }
            }
            if let content = window.contentView {
                func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
                func layers(_ layer: CALayer, _ depth: Int) {
                    out += String(repeating: "  ", count: depth) + "LAYER \(type(of: layer)) \(layer.frame) bg=\(layer.backgroundColor?.components ?? []) op=\(layer.opacity) filters=\(String(describing: layer.filters)) comp=\(String(describing: layer.compositingFilter)) hidden=\(layer.isHidden)\n"
                    layer.sublayers?.forEach { layers($0, depth + 1) }
                }
                for effect in all(content).compactMap({ $0 as? NSVisualEffectView }) {
                    if let layer = effect.layer { layers(layer, 0) }
                }
            }
            try? out.write(toFile: path, atomically: true, encoding: .utf8)
            // The app's own windows, composited, where screen capture of
            // the whole screen is not permitted.
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
                let capture = unsafeBitCast(symbol, to: Capture.self)
                for other in NSApp.windows where other.isVisible && other.frame.width > 500 {
                    // 1 << 3: this window alone; 1: bounds ignore framing.
                    if let image = capture(.null, 1 << 3, UInt32(other.windowNumber), 1)?.takeRetainedValue() {
                        let url = URL(fileURLWithPath: path + ".\(type(of: other)).png")
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                    }
                }
            }
            if !windowed { window.toggleFullScreen(nil) }
        }
    }
    #endif

    #if DEBUG
    /// DEBUG-SNAPSHOT (temporary): draws the library offscreen to PNGs,
    /// light and dark, where screen capture is not permitted.
    private static func snapshotForDebugging(_ window: NSWindow) {
        guard let dir = ProcessInfo.processInfo.environment["PAPER_LIBRARY_SNAPSHOT"],
              let folder = windows.first(where: { $0.value === window })?.key else { return }
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
                    let view = LibraryView(navigation: LibraryNavigation(root: folder), listing: listing, scrolls: false)
                        .frame(width: 1280, height: 820)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let sample = LibraryMenuRequest(point: CGPoint(x: 420, y: 300), items: [
                        LibraryMenuItem(title: "Open", glyph: OpenGlyph()) {},
                        LibraryMenuItem(title: "Reveal in Finder", glyph: RevealGlyph()) {},
                        LibraryMenuItem(title: "Copy Path", glyph: CopyGlyph()) {},
                        LibraryMenuItem(title: "Move to Trash", glyph: TrashGlyph()) {},
                    ])
                    let withMenu = view.overlay(LibraryMenuLayer(request: .constant(sample)))
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let menuRenderer = ImageRenderer(content: withMenu)
                    menuRenderer.scale = 2
                    if let image = menuRenderer.cgImage {
                        let url = URL(fileURLWithPath: dir).appendingPathComponent(dark ? "menu-dark.png" : "menu-light.png")
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                    }
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
