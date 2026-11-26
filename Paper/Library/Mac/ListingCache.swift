import Foundation

/// Names for new notes and folders: the plain name, then numbered.
enum LibraryNames {
    static func unused(_ base: String, extension ext: String, in folder: URL) -> URL {
        func url(_ name: String) -> URL {
            let url = folder.appendingPathComponent(name, isDirectory: ext.isEmpty)
            return ext.isEmpty ? url : url.appendingPathExtension(ext)
        }
        var candidate = url(base)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url("\(base) \(index)")
            index += 1
        }
        return candidate
    }
}

/// Folders as last read, so going into one, or back out, shows its cards
/// at once while it is read again. A folder card under the pointer is
/// read ahead, before the click.
@MainActor
enum ListingCache {
    struct Entry: Sendable {
        let listing: FolderListing
        let hidden: Set<URL>
    }

    private struct Key: Hashable {
        let folder: URL
        let showsHidden: Bool
    }

    private static var entries: [Key: Entry] = [:]
    private static var order: [Key] = []
    private static let limit = 64

    /// Folders being read ahead now, so a pointer passing over a card
    /// twice reads it once.
    private static var reading: Set<Key> = []

    static func get(_ folder: URL, showsHidden: Bool) -> Entry? {
        let key = Key(folder: folder.standardizedFileURL, showsHidden: showsHidden)
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry
    }

    /// Reads the folder off the main thread and keeps the result.
    static func read(_ folder: URL, showsHidden: Bool) async -> Entry {
        let read = await Task.detached(priority: .userInitiated) {
            // The notes as the iPhone lists them, then the Mac's pictures
            // and videos among them.
            let (notes, hiddenNotes) = showsHidden
                ? FolderListing.loadIncludingHidden(folder)
                : (FolderListing.load(folder, isDefaultRoot: false), [])
            let (listing, hidden) = FolderListing.addingMedia(
                to: notes, hidden: hiddenNotes, in: folder, includingHidden: showsHidden
            )
            return Entry(listing: listing, hidden: hidden)
        }.value
        // An untitled note waits at the end of the notes, where a new one
        // appears, until its title names it.
        var listing = read.listing
        let untitled = listing.notes.filter { NoteNaming.isUntitled($0.url) }
        if !untitled.isEmpty {
            listing.notes = listing.notes.filter { !NoteNaming.isUntitled($0.url) } + untitled.reversed()
        }
        let entry = Entry(listing: listing, hidden: read.hidden)
        store(entry, Key(folder: folder.standardizedFileURL, showsHidden: showsHidden))
        // Pictures start as soon as the folder is known, before any tile.
        MediaPicture.prefetch(listing.notes)
        return entry
    }

    static func prefetch(_ folder: URL, showsHidden: Bool) {
        let key = Key(folder: folder.standardizedFileURL, showsHidden: showsHidden)
        guard entries[key] == nil, !reading.contains(key) else { return }
        reading.insert(key)
        Task {
            _ = await read(folder, showsHidden: showsHidden)
            reading.remove(key)
        }
    }

    /// Kept newest-used last; the least recently used go first.
    private static func store(_ entry: Entry, _ key: Key) {
        entries[key] = entry
        touch(key)
        while order.count > limit { entries[order.removeFirst()] = nil }
    }

    private static func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
