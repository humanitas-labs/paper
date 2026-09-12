import AppKit
import SwiftUI

/// The file name in the window's top-left corner, the zoom badge's
/// mirror. Nothing at rest: it shows for a moment when the document
/// opens or its file changes, and comes back while the pointer rests in
/// that corner. The full path is the tooltip; a click opens a menu that
/// copies the path or the name, or shows the file in Finder.
struct FileBadge: View {
    let fileURL: URL?
    /// Observed so the pill follows theme changes.
    @ObservedObject private var store = ConfigurationStore.shared
    @State private var flashed = false
    @State private var zoneHovering = false
    @State private var pillHovering = false
    @State private var visible = false
    @State private var hide: Task<Void, Never>?
    @State private var settle: Task<Void, Never>?

    /// The zone (SwiftUI) and the pill (AppKit) report hover separately,
    /// and the pointer crossing from one to the other can report the exit
    /// after the entry; either keeps the pill up, and a short grace before
    /// hiding rides over the gap.
    private var wanted: Bool { flashed || zoneHovering || pillHovering }

    /// What the pill says: the file's name, or `Untitled` before a save.
    nonisolated static func title(for url: URL?) -> String {
        url?.lastPathComponent ?? "Untitled"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The hot zone: resting the pointer here brings the badge back.
            // It reaches over the traffic lights, which is harmless; the
            // pill itself sits to their right.
            Color.clear
                .frame(width: 240, height: 64)
                .contentShape(Rectangle())
                .onHover { zoneHovering = $0 }
            Text(Self.title(for: fileURL))
                .badgePill()
                .overlay(MenuAnchor(fileURL: fileURL, hovering: $pillHovering))
                .padding(.top, 14)
                .padding(.leading, 96)
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
                .animation(.easeInOut(duration: 0.18), value: visible)
        }
        .onChange(of: wanted, initial: true) { _, wanted in
            settle?.cancel()
            if wanted {
                visible = true
            } else {
                settle = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    visible = false
                }
            }
        }
        .onChange(of: fileURL) { _, _ in flash() }
        .onAppear { if fileURL != nil { flash() } }
    }

    private func flash() {
        hide?.cancel()
        flashed = true
        hide = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            flashed = false
        }
    }
}

/// An AppKit view over the pill: it carries the tooltip, keeps the hover
/// alive while the pointer is on the pill, and pops the menu on a click
/// of either button.
private struct MenuAnchor: NSViewRepresentable {
    let fileURL: URL?
    @Binding var hovering: Bool

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onHover = { hovering = $0 }
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.fileURL = fileURL
        view.toolTip = fileURL?.path ?? "Not saved yet"
        view.onHover = { hovering = $0 }
    }

    final class AnchorView: NSView {
        var fileURL: URL?
        var onHover: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true); NSCursor.pointingHand.set() }
        override func mouseExited(with event: NSEvent) { onHover?(false); NSCursor.arrow.set() }
        override func mouseDown(with event: NSEvent) { popUp() }
        override func rightMouseDown(with event: NSEvent) { popUp() }

        private func popUp() {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let path = NSMenuItem(title: "Copy Path", action: #selector(copyPath), keyEquivalent: "")
            path.target = self
            path.isEnabled = fileURL != nil
            let name = NSMenuItem(title: "Copy Name", action: #selector(copyName), keyEquivalent: "")
            name.target = self
            let finder = NSMenuItem(title: "Show in Finder", action: #selector(reveal), keyEquivalent: "")
            finder.target = self
            finder.isEnabled = fileURL != nil
            // The menu bar item's list (#77); the same toggle as File ▸ Pin.
            let pinned = fileURL.map(PinStore.shared.pins.contains) == true
            let pin = NSMenuItem(title: pinned ? "Unpin Document" : "Pin Document", action: #selector(togglePin), keyEquivalent: "")
            pin.target = self
            pin.isEnabled = fileURL != nil
            let rename = NSMenuItem(title: "Rename Pin…", action: #selector(renamePin), keyEquivalent: "")
            rename.target = self
            rename.isEnabled = pinned
            menu.items = [path, name, .separator(), finder, .separator(), pin, rename]
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: self)
        }

        @objc private func copyPath() { if let fileURL { DocumentPath.copy(fileURL) } }
        @objc private func copyName() { DocumentPath.copyName(fileURL) }
        @objc private func reveal() { if let fileURL { DocumentPath.reveal(fileURL) } }
        @objc private func togglePin() { if let fileURL { PinStore.shared.toggle(fileURL) } }

        /// The name the pin goes by in the menu bar; blank returns it to
        /// the file name.
        @objc private func renamePin() {
            guard let fileURL, let pin = PinStore.shared.pins.pin(for: fileURL) else { return }
            let alert = NSAlert()
            alert.messageText = "Name this pin"
            alert.informativeText = "Shown in the menu bar in place of \(fileURL.lastPathComponent). Leave it empty to use the file name."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.stringValue = pin.name ?? ""
            field.placeholderString = fileURL.lastPathComponent
            alert.accessoryView = field
            alert.addButton(withTitle: "Name")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            PinStore.shared.rename(fileURL, to: field.stringValue)
        }
    }
}
