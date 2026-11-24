import AppKit

/// Opening a folder in Paper gives a library window; opening a file gives a
/// document window, as always. SwiftUI's document controller only knows
/// documents, so folders are sorted out here before it sees them.
@MainActor
enum LibraryOpening {
    /// Opens each folder as a library and hands the files on to the
    /// document controller.
    static func open(_ urls: [URL]) {
        for url in urls {
            if isFolder(url) {
                LibraryWindow.open(url)
            } else {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            }
        }
    }

    /// File ▸ Open Folder…: a panel for folders only.
    static func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose a folder to see its notes as cards."
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    // MARK: Recent folders

    /// Folders opened, newest first. AppKit's recents would hand a folder
    /// to the document system, which cannot open one, so the library keeps
    /// its own list for the welcome window.
    private static let recentsKey = "libraryRecentFolders"
    static let maximumRecents = 5

    static var recentFolders: [URL] {
        (UserDefaults.standard.stringArray(forKey: recentsKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func noteRecent(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(maximumRecents)), forKey: recentsKey)
    }

    /// A folder, not a package such as a bundle or an `.rtfd`.
    static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }
}
