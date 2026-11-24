import AppKit
import Combine

/// Where a library window is: the folder opened, the folder shown, and the
/// folders walked through, for Back and Forward as in Finder. The grid and
/// the window's toolbar both read and drive it.
@MainActor
final class LibraryNavigation: ObservableObject {
    /// The folder opened: the library goes no higher.
    let root: URL
    /// The folder shown, the root or one under it.
    @Published private(set) var folder: URL
    @Published private(set) var history: [URL] = []
    @Published private(set) var forward: [URL] = []

    init(root: URL) {
        self.root = root.standardizedFileURL
        folder = root.standardizedFileURL
    }

    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func go(to target: URL) {
        let target = target.standardizedFileURL
        guard target != folder else { return }
        history.append(folder)
        forward.removeAll()
        folder = target
    }

    func goUp() {
        guard folder != root else { return }
        go(to: folder.deletingLastPathComponent())
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        forward.append(folder)
        folder = previous
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        history.append(folder)
        folder = next
    }
}

/// The library window's toolbar: Finder's back and forward, placed before
/// the title as a navigational item, so the system draws them and they
/// take clicks where the window's title band would otherwise drag.
@MainActor
final class LibraryToolbar: NSObject, NSToolbarDelegate {
    static let identifier = NSToolbar.Identifier("org.humanitas.paper.library")
    private static let navigationItem = NSToolbarItem.Identifier("navigation")

    private let navigation: LibraryNavigation
    private weak var window: NSWindow?
    private var group: NSToolbarItemGroup?
    private var watching: AnyCancellable?

    init(navigation: LibraryNavigation, window: NSWindow) {
        self.navigation = navigation
        self.window = window
        super.init()
        let toolbar = NSToolbar(identifier: Self.identifier)
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        // After each change settles, so the arrows and the title read
        // the new place.
        watching = navigation.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refresh()
        }
        refresh()
        // A mouse's side buttons go back and forward, as in a browser:
        // button 3 is "back" (mouse 4) and button 4 "forward" (mouse 5).
        sideButtons = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            switch event.buttonNumber {
            case 3: self.navigation.goBack()
            case 4: self.navigation.goForward()
            default: return event
            }
            return nil
        }
    }

    /// Stops listening for the side buttons. Called as the window closes.
    func stop() {
        if let sideButtons { NSEvent.removeMonitor(sideButtons) }
        sideButtons = nil
        watching = nil
    }

    private var sideButtons: Any?

    private func refresh() {
        window?.title = navigation.folder.lastPathComponent
        window?.representedURL = navigation.folder
        guard let group else { return }
        let enabled = [navigation.canGoBack, navigation.canGoForward]
        for (index, item) in group.subitems.enumerated() where index < enabled.count {
            item.isEnabled = enabled[index]
        }
        if let control = group.view as? NSSegmentedControl {
            for (index, on) in enabled.enumerated() { control.setEnabled(on, forSegment: index) }
        }
    }

    @objc private func navigate(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0 { navigation.goBack() } else { navigation.goForward() }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.navigationItem] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.navigationItem] }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.navigationItem else { return nil }
        let images = ["chevron.left", "chevron.right"].map {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) ?? NSImage()
        }
        let group = NSToolbarItemGroup(
            itemIdentifier: itemIdentifier, images: images, selectionMode: .momentary,
            labels: ["Back", "Forward"], target: self, action: #selector(navigate(_:))
        )
        group.isNavigational = true
        group.autovalidates = false
        group.subitems.forEach { $0.autovalidates = false }
        group.label = "Back/Forward"
        self.group = group
        DispatchQueue.main.async { [weak self] in self?.refresh() }
        return group
    }
}
