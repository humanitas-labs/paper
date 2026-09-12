import AppKit

/// Paper's item in the menu bar (#77): the pinned documents, then the
/// recent ones, then New and Open. Behind `menu.bar` in the config; the
/// item comes and goes as the key changes, on by default. The menu is rebuilt each time
/// it opens, so it reflects pins, recents, and files that have come or
/// gone since the last click.
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    static let shared = MenuBarItem()

    private var statusItem: NSStatusItem?

    /// Creates or removes the item to match the configuration.
    func sync(_ configuration: Configuration) {
        if configuration.menuBar {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = Self.mark
            item.button?.toolTip = "Paper"
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
            statusItem = item
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    /// Follows the config from now on; one call at launch.
    func start(store: ConfigurationStore = .shared) {
        sync(store.current)
        NotificationCenter.default.addObserver(
            forName: Configuration.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MenuBarItem.shared.sync(ConfigurationStore.shared.current) }
        }
    }

    /// The Enso as a template image, so it takes the bar's tint in either
    /// appearance, at the size the bar's own symbols draw.
    private static var mark: NSImage? {
        guard let image = NSImage(named: "Enso")?.copy() as? NSImage else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let pinned = MenuBarModel.pinned(PinStore.shared.pins)
        if pinned.isEmpty {
            let none = NSMenuItem(title: "No Pinned Documents", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for entry in pinned {
            let item = documentItem(entry.url, symbol: "pin.fill")
            if entry.missing {
                item.attributedTitle = NSAttributedString(
                    string: entry.name, attributes: [.foregroundColor: NSColor.tertiaryLabelColor]
                )
            }
            menu.addItem(item)
        }
        let recents = WelcomeModel.recents(from: NSDocumentController.shared.recentDocumentURLs)
            .filter { recent in !pinned.contains { $0.url == recent.url } }
        if !recents.isEmpty {
            menu.addItem(.separator())
            for recent in recents { menu.addItem(documentItem(recent.url, symbol: "clock")) }
        }
        menu.addItem(.separator())
        let new = NSMenuItem(title: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "")
        new.target = NSDocumentController.shared
        menu.addItem(new)
        let open = NSMenuItem(title: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "")
        open.target = NSDocumentController.shared
        menu.addItem(open)
    }

    /// A pin marks the pinned, a clock the recent; the symbol says which
    /// group an item is in where the two run together.
    private func documentItem(_ url: URL, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: url.lastPathComponent, action: #selector(open(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.representedObject = url
        item.toolTip = (url.path as NSString).abbreviatingWithTildeInPath
        return item
    }

    /// Fronts the document if it is open, opens it if not, and says so if
    /// the file is not there. Paper may be in the back when the click
    /// comes, so it activates either way.
    @objc private func open(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSApp.activate()
        if let document = NSDocumentController.shared.document(for: url) {
            document.showWindows()
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            missing(url)
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }

    private func missing(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "\(url.lastPathComponent) is not there"
        alert.informativeText = "There is no file at \((url.path as NSString).abbreviatingWithTildeInPath). It stays pinned in case it comes back; unpin it to forget it."
        alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Unpin")
        if alert.runModal() == .alertSecondButtonReturn {
            PinStore.shared.remove(url)
        }
    }
}
