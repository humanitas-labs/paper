import AppKit

/// Launch behaviour the document group leaves to AppKit. SwiftUI answers a
/// launch with nothing to open by running an Open panel before the app
/// finishes launching and never forwards the untitled-file hooks, so the
/// panel is the signal: when it is up at launch, it is dismissed for the
/// welcome window, or on the first launch for the welcome document. A
/// launch with a file, or with restored windows, has no panel and is
/// untouched.
///
/// The `paper` command installs itself here too, first, so the welcome
/// document can say where it went.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Not under tests: the test host would put the link on the
        // tester's PATH, open the guide over the test run, and build the
        // welcome window from the run loop inside a test's task, where the
        // main-actor executor check faults.
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let panel = NSApp.windows.first(where: { $0 is NSOpenPanel }) as? NSOpenPanel
        panel?.cancel(nil)
        guard !testing else { return }
        UpdateCheck.runIfDue(configuration: ConfigurationStore.shared.current)
        PinStore.shared.start()
        MenuBarItem.shared.start()
        let firstLaunch = ConfigurationStore.shared.isFirstLaunch
        if panel != nil, !firstLaunch { WelcomeWindow.show() }
        Task {
            await CommandLineTool.shared.installQuietly()
            if panel != nil, firstLaunch { await WelcomeDocument.open(replacing: true) }
        }
    }

    /// A Dock click while no window is open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows { return true }
        WelcomeWindow.show()
        return false
    }
}
