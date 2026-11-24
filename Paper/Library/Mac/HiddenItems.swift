import Foundation

/// The items Finder hides, a dot at the head of the name or the hidden
/// flag, which ⇧⌘. shows in the library as it does in Finder. The listing
/// the iPhone shares leaves them out; the Mac adds them here.
extension FolderListing {
    /// Whether the library shows hidden items, in every library window.
    static let showsHiddenKey = "libraryShowsHidden"

    /// The folder's listing with its hidden folders and notes merged in,
    /// in the same order, and which of the items are the hidden ones.
    static func loadIncludingHidden(_ folder: URL) -> (listing: FolderListing, hidden: Set<URL>) {
        var listing = load(folder, isDefaultRoot: false)
        let shown = Set(listing.folders.map(\.url) + listing.notes.map(\.url))
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .isPackageKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: []
        )) ?? []
        var hidden: Set<URL> = []
        for entry in entries where !shown.contains(entry) {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, values?.isPackage != true {
                listing.folders.append(Folder(url: entry, name: entry.lastPathComponent, itemCount: count(in: entry)))
                hidden.insert(entry)
            } else if noteExtensions.contains(entry.pathExtension.lowercased()) {
                listing.notes.append(Note(
                    url: entry, title: title(of: entry),
                    modified: values?.contentModificationDate ?? .distantPast
                ))
                hidden.insert(entry)
            }
        }
        listing.folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        listing.notes.sort { $0.modified > $1.modified }
        return (listing, hidden)
    }

    /// Folders and notes directly inside, hidden ones too, since they show.
    private static func count(in folder: URL) -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )) ?? []
        return entries.filter { entry in
            (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                || noteExtensions.contains(entry.pathExtension.lowercased())
        }.count
    }
}
