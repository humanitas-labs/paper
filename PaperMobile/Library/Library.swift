import Foundation
import SwiftUI

/// The folder the app opens on. It defaults to the app's own Documents
/// folder and can be pointed at any folder in Files (iCloud Drive, Working
/// Copy, On My iPhone); the choice is kept as a bookmark so the app starts
/// there next time.
@MainActor
final class LibraryRoot: ObservableObject {
    static let shared = LibraryRoot()
    private static let bookmarkKey = "libraryRootBookmark"

    @Published private(set) var url: URL

    private init() {
        url = Self.restore() ?? URL.documentsDirectory
    }

    var isDefault: Bool { url == URL.documentsDirectory }

    /// Adopts a folder picked in Files and remembers it.
    func choose(_ folder: URL) {
        guard folder.startAccessingSecurityScopedResource() else { return }
        if !isDefault { url.stopAccessingSecurityScopedResource() }
        if let bookmark = try? folder.bookmarkData() {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
        url = folder
    }

    func reset() {
        if !isDefault { url.stopAccessingSecurityScopedResource() }
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        url = URL.documentsDirectory
    }

    private static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              folder.startAccessingSecurityScopedResource()
        else { return nil }
        if stale, let fresh = try? folder.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return folder
    }
}

/// One folder's contents as the library shows them: subfolders first, then
/// Markdown notes, newest first.
struct FolderListing: Sendable {
    struct Folder: Identifiable, Hashable, Sendable {
        let url: URL
        let name: String
        let itemCount: Int
        var id: URL { url }
    }

    struct Note: Identifiable, Hashable, Sendable {
        let url: URL
        let title: String
        let modified: Date
        var id: URL { url }
    }

    var folders: [Folder] = []
    var notes: [Note] = []

    static let noteExtensions: Set<String> = ["md", "markdown", "mdown", "txt"]
    /// Paper's own settings live beside the notes in the default root.
    static let hiddenAtDefaultRoot: Set<String> = ["presets", "themes", "config"]

    static func load(_ folder: URL, isDefaultRoot: Bool) -> FolderListing {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .isPackageKey]
        let entries = (try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        var listing = FolderListing()
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let name = entry.lastPathComponent
            if isDefaultRoot, hiddenAtDefaultRoot.contains(name) { continue }
            if values?.isDirectory == true, values?.isPackage != true {
                listing.folders.append(Folder(url: entry, name: name, itemCount: itemCount(in: entry)))
            } else if noteExtensions.contains(entry.pathExtension.lowercased()) {
                listing.notes.append(Note(
                    url: entry, title: title(of: entry),
                    modified: values?.contentModificationDate ?? .distantPast
                ))
            }
        }
        listing.folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        listing.notes.sort { $0.modified > $1.modified }
        return listing
    }

    /// Notes and folders directly inside `folder`.
    private static func itemCount(in folder: URL) -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { entry in
            (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                || noteExtensions.contains(entry.pathExtension.lowercased())
        }.count
    }

    /// The note's first `# ` heading, as Notes takes its first line; the
    /// file name otherwise. Only the head of the file is read.
    static func title(of file: URL) -> String {
        let fallback = file.deletingPathExtension().lastPathComponent
        guard let handle = try? FileHandle(forReadingFrom: file) else { return fallback }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        let text = String(decoding: head, as: UTF8.self)
        var inFrontMatter = false
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if index == 0, trimmed == "---" { inFrontMatter = true; continue }
            if inFrontMatter { if trimmed == "---" { inFrontMatter = false }; continue }
            if trimmed.hasPrefix("# ") {
                let heading = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return heading.isEmpty ? fallback : heading
            }
        }
        return fallback
    }
}

/// Reads and writes a note in place, coordinated with Files and iCloud.
enum NoteFile {
    static func read(_ url: URL) throws -> String {
        var result: Result<String, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try MarkdownDocument(data: Data(contentsOf: url)).text }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    static func write(_ text: String, to url: URL) throws {
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            result = Result { try MarkdownDocument(text: text).data.write(to: url, options: .atomic) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }
}
