import AppKit
import SwiftUI

/// Applies Mac window behavior that SwiftUI does not expose. The host view
/// configures its window every time it is attached, so the setup is idempotent
/// and does not depend on the window existing when the view is created.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> HostView {
        HostView(frame: .zero)
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.configureWindow()
    }

    final class HostView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            window?.applyPaperChrome(minSize: NSSize(width: 640, height: 520))
        }
    }
}

extension NSWindow {
    static let chromeToolbarIdentifier = NSToolbar.Identifier("org.humanitas.paper.chrome")

    /// The Paper window: hidden title, transparent title bar, the content
    /// under it, and corners rounder than the system default. Idempotent.
    func applyPaperChrome(minSize: NSSize) {
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        styleMask.insert(.fullSizeContentView)
        // An empty unified toolbar is the supported way to a taller
        // title area: the traffic lights sit further in and down, as in
        // Spatial, without repositioning the buttons by hand.
        if toolbar?.identifier != Self.chromeToolbarIdentifier {
            let chrome = NSToolbar(identifier: Self.chromeToolbarIdentifier)
            chrome.allowsUserCustomization = false
            toolbar = chrome
        }
        toolbarStyle = .unified
        isMovableByWindowBackground = true
        self.minSize = minSize
        observeFullScreen()
        applyFullScreenState(styleMask.contains(.fullScreen))
    }

    /// The empty toolbar only places the traffic lights, which full screen
    /// hides. Left visible there it showed as a band above the page, drawn
    /// in the system appearance, so it is hidden in full screen and the
    /// corners square off to the screen.
    fileprivate func applyFullScreenState(_ full: Bool) {
        toolbar?.isVisible = !full
        applyCorners(radius: full ? 0 : Appearance.windowCornerRadius)
    }

    private func observeFullScreen() {
        guard FullScreenObservers.windows.insert(ObjectIdentifier(self)).inserted else { return }
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyFullScreenState(true) }
        }
        center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyFullScreenState(false) }
        }
    }

    /// Places the window in the exact middle of its screen's visible area,
    /// shrunk to fit it if need be. `center()` sits a window somewhat
    /// above the middle by design, which reads as too high when the
    /// window nearly fills the screen.
    func centerExactly() {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { center(); return }
        var size = frame.size
        size.width = min(size.width, visible.width)
        size.height = min(size.height, visible.height)
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// The window rounds more than the system default: the content view
    /// is masked with a continuous corner and the window itself is
    /// clear, so the shadow follows the mask.
    private func applyCorners(radius: CGFloat) {
        guard let content = contentView else { return }
        backgroundColor = .clear
        isOpaque = false
        content.wantsLayer = true
        content.layer?.backgroundColor = Appearance.canvas.cgColor
        content.layer?.cornerRadius = radius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        invalidateShadow()
    }
}

/// Windows already observed for full-screen changes, so configuring a window
/// again does not add a second pair of observers.
@MainActor private enum FullScreenObservers {
    static var windows: Set<ObjectIdentifier> = []
}
