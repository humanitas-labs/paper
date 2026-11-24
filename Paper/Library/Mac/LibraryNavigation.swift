import AppKit
import Combine

/// Where a library window is: the folder opened, the folder shown, and the
/// folders walked through, for Back and Forward as in Finder. The grid and
/// the window's toolbar both read and drive it.
@MainActor
final class LibraryNavigation: ObservableObject {
    /// The folder opened: the library goes no higher.
    let root: URL
    /// A tab, as in Finder: a folder shown and the way it was reached.
    struct Tab: Identifiable, Equatable {
        let id = UUID()
        var folder: URL
        var history: [URL] = []
        var forward: [URL] = []
    }

    /// The window's tabs, and the one in front. A window starts with one
    /// and shows no tab bar until it has two.
    @Published private(set) var tabs: [Tab]
    @Published private(set) var front = 0

    /// The folder shown in the front tab, the root or one under it.
    private(set) var folder: URL {
        get { tabs[front].folder }
        set { tabs[front].folder = newValue }
    }
    private var history: [URL] {
        get { tabs[front].history }
        set { tabs[front].history = newValue }
    }
    private var forward: [URL] {
        get { tabs[front].forward }
        set { tabs[front].forward = newValue }
    }

    /// Right clicks (and Control-clicks) in the window, where they landed
    /// in its content from the top left. The window hears them, so no view
    /// has to sit over the cards to catch them.
    let secondaryClicks = PassthroughSubject<CGPoint, Never>()
    /// Plain clicks in the window's content, reported the same way and
    /// passed on untouched: the grid uses them to let go of what is picked
    /// when a click lands on empty space, which the scroll view would
    /// otherwise keep to itself.
    let primaryClicks = PassthroughSubject<CGPoint, Never>()
    /// Whether the window is in full screen, where the system's toolbar
    /// is put away and the grid draws the header itself.
    @Published var fullScreen = false
    /// What the grid shows, for agent apps (LibraryContext.swift).
    var snapshot = LibrarySnapshot() {
        didSet {
            guard snapshot != oldValue else { return }
            NotificationCenter.default.post(name: Self.contextDidChange, object: self)
        }
    }
    /// Where the grid's cards are, for agent apps asking where one is.
    var frames: CardFrames?
    /// The library's window, for placing what opens from it on screen.
    weak var window: NSWindow?

    init(root: URL) {
        self.root = root.standardizedFileURL
        tabs = [Tab(folder: root.standardizedFileURL)]
    }

    // MARK: Tabs

    /// A new tab after the front one, on `folder` or else the library's
    /// root (⌘T starts fresh, as a browser's new tab does), brought
    /// forward unless `behind`.
    func openTab(_ folder: URL? = nil, behind: Bool = false) {
        tabs.insert(Tab(folder: (folder ?? root).standardizedFileURL), at: front + 1)
        if !behind { front += 1 }
    }

    func showTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        front = index
    }

    func showNextTab(_ step: Int) {
        guard tabs.count > 1 else { return }
        front = (front + step + tabs.count) % tabs.count
    }

    /// Closes a tab; false when it is the last, which closes the window.
    @discardableResult
    func closeTab(_ index: Int? = nil) -> Bool {
        let index = index ?? front
        guard tabs.count > 1, tabs.indices.contains(index) else { return false }
        tabs.remove(at: index)
        if front > index || front == tabs.count { front = max(front - 1, 0) }
        return true
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
        // The grid draws the name itself, in a pill of the page's color.
        window.titleVisibility = .hidden
        // After each change settles, so the arrows and the title read
        // the new place.
        watching = navigation.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refresh()
        }
        refresh()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setFullScreen(true) }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setFullScreen(false) }
            },
            center.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.styleScroller() }
            },
        ]
        DispatchQueue.main.async { [weak self] in self?.styleScroller() }
        // A mouse's side buttons go back and forward, as in a browser:
        // button 3 is "back" (mouse 4) and button 4 "forward" (mouse 5).
        sideButtons = NSEvent.addLocalMonitorForEvents(
            matching: [.otherMouseDown, .rightMouseDown, .leftMouseDown]
        ) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            switch event.type {
            case .otherMouseDown:
                switch event.buttonNumber {
                case 3: self.navigation.goBack()
                case 4: self.navigation.goForward()
                default: return event
                }
                return nil
            case .leftMouseDown where !event.modifierFlags.contains(.control):
                if let point = self.contentPoint(of: event, in: window) {
                    self.navigation.primaryClicks.send(point)
                }
                return event
            default:
                // A right click, or a Control-click, below the toolbar.
                guard let point = self.contentPoint(of: event, in: window) else { return event }
                self.navigation.secondaryClicks.send(point)
                return nil
            }
        }
    }

    /// Where a click landed in the window's content, from its top left;
    /// nil in the toolbar or outside the content.
    private func contentPoint(of event: NSEvent, in window: NSWindow) -> CGPoint? {
        guard let content = window.contentView else { return nil }
        let point = content.convert(event.locationInWindow, from: nil)
        let fromTop = content.isFlipped ? point.y : content.bounds.height - point.y
        let toolbarHeight = content.bounds.height - window.contentLayoutRect.height
        guard content.bounds.contains(point), fromTop > toolbarHeight else { return nil }
        return CGPoint(x: point.x, y: fromTop)
    }

    /// Stops listening for the side buttons. Called as the window closes.
    func stop() {
        if let sideButtons { NSEvent.removeMonitor(sideButtons) }
        sideButtons = nil
        watching = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private var observers: [NSObjectProtocol] = []

    /// The document's scroller: the wide one with a track under it,
    /// hidden while everything fits. SwiftUI owns the scroll view, so
    /// the style is set on it here and again whenever the system would
    /// change it (a mouse coming or going).
    private func styleScroller() {
        guard let content = window?.contentView else { return }
        for scrollView in Self.descendants(of: content).compactMap({ $0 as? NSScrollView }) {
            scrollView.scrollerStyle = .legacy
            scrollView.autohidesScrollers = true
            // AppKit sets the pointer over a scroll view's content
            // itself, and its arrow came back at times.
            scrollView.documentCursor = LibraryPointer.cursor
        }
    }

    /// In full screen the system moves the toolbar to a window of its
    /// own and paints an opaque band and a hairline behind it, which no
    /// setting takes away. The toolbar is put away there instead, and the
    /// grid draws the same header on its own page.
    private func setFullScreen(_ full: Bool) {
        window?.toolbar?.isVisible = !full
        navigation.fullScreen = full
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
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
