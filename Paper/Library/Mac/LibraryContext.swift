import AppKit

/// What a library window shows, for the Ambient Context Protocol: the
/// folder, its folders and notes, which are picked and which is under the
/// pointer. The grid keeps it current; Paper's provider reads it.
struct LibrarySnapshot: Equatable {
    var folders: [FolderListing.Folder] = []
    var notes: [FolderListing.Note] = []
    var hidden: Set<URL> = []
    var selection: Set<URL> = []
    var hovered: URL?
}

extension LibraryNavigation {
    /// Posted, with the navigation as its object, whenever what the
    /// library shows may have changed.
    static let contextDidChange = Notification.Name("paper.library.contextDidChange")

    /// Where a card is on screen, or nil when it is not drawn (scrolled
    /// out of the grid, which draws only the rows near view).
    func screenFrame(of url: URL) -> NSRect? {
        guard let frame = frames?.rects[url], let window, let content = window.contentView else { return nil }
        let inContent = NSRect(
            x: frame.minX, y: content.isFlipped ? frame.minY : content.bounds.height - frame.maxY,
            width: frame.width, height: frame.height
        )
        let onScreen = window.convertToScreen(content.convert(inContent, to: nil))
        // A card scrolled under the toolbar or past the foot is not seen.
        return onScreen.intersects(window.convertToScreen(content.convert(content.bounds, to: nil))) ? onScreen : nil
    }
}

/// The library windows as context elements. Ids are minted once per
/// window, folder shown and item, and kept while they live.
@MainActor
final class LibraryContextTree {
    private final class Ref {
        weak var navigation: LibraryNavigation?
        let url: URL?
        init(_ navigation: LibraryNavigation, _ url: URL?) {
            self.navigation = navigation
            self.url = url
        }
    }

    /// The most items reported for one folder; past it the list says so.
    static let itemLimit = 1000

    private var counter = 0
    private var issued: [String: Ref] = [:]
    private var known: [String: String] = [:]

    func owns(_ id: String) -> Bool { issued[id] != nil }

    /// A library window, its folder as a `List`, and a `Row` for each
    /// folder and note in it:
    ///
    ///     Window [library] → List [folder] → Row [folder | note]
    func element(for navigation: LibraryNavigation, front: Bool) -> ContextElement {
        let snapshot = navigation.snapshot
        let folder = navigation.folder
        var rows: [ContextElement] = []
        for item in snapshot.folders {
            var row = ContextElement(
                id: id("item", navigation, item.url), role: .row, subrole: "folder", title: item.name,
                url: item.url.absoluteString, selected: snapshot.selection.contains(item.url),
                hovered: front && snapshot.hovered == item.url,
                attributes: ["item_count": .integer(item.itemCount)]
            )
            if snapshot.hidden.contains(item.url) { row.attributes?["hidden"] = .bool(true) }
            rows.append(row)
        }
        for note in snapshot.notes {
            var attributes: [String: ContextValue] = ["file_name": .string(note.url.lastPathComponent)]
            if snapshot.hidden.contains(note.url) { attributes["hidden"] = .bool(true) }
            rows.append(ContextElement(
                id: id("item", navigation, note.url), role: .row, subrole: "note", title: note.title,
                url: note.url.absoluteString, selected: snapshot.selection.contains(note.url),
                hovered: front && snapshot.hovered == note.url, attributes: attributes
            ))
        }
        var listAttributes: [String: ContextValue] = [
            "folders": .integer(snapshot.folders.count),
            "notes": .integer(snapshot.notes.count),
        ]
        if rows.count > Self.itemLimit {
            rows = Array(rows.prefix(Self.itemLimit))
            listAttributes["truncated"] = .bool(true)
        }
        let list = ContextElement(
            id: id("folder", navigation, folder), role: .list, subrole: "folder", title: folder.lastPathComponent,
            url: folder.absoluteString, focused: front, children: rows, attributes: listAttributes
        )
        var window = ContextElement(
            id: id("libwin", navigation, nil), role: .window, subrole: "library", focused: front, children: [list]
        )
        if let shown = navigation.window, !shown.isVisible || shown.isMiniaturized { window.visible = false }
        return window
    }

    /// The line a host shows for a library in front: the folder, and what
    /// is picked in it, or what it holds when nothing is.
    ///
    ///     Renaissance · 3 selected
    ///     Renaissance · Thesis.md
    ///     Renaissance · 24 notes, 5 folders
    func display(for navigation: LibraryNavigation) -> ContextDisplay {
        let snapshot = navigation.snapshot
        let detail: String
        if snapshot.selection.count == 1, let url = snapshot.selection.first {
            detail = url.lastPathComponent
        } else if !snapshot.selection.isEmpty {
            detail = "\(snapshot.selection.count) selected"
        } else {
            func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
            detail = "\(count(snapshot.notes.count, "note")), \(count(snapshot.folders.count, "folder"))"
        }
        return ContextDisplay(title: navigation.folder.lastPathComponent, detail: detail)
    }

    func locate(_ id: String) -> ContextLocation? {
        guard let ref = issued[id] else { return nil }
        guard let navigation = ref.navigation, let window = navigation.window, window.isVisible else { return .gone(id) }
        guard !window.isMiniaturized else { return ContextLocation(id: id, state: .offscreen, window: window.windowNumber) }
        if id.hasPrefix("libwin-") || id.hasPrefix("folder-") {
            if id.hasPrefix("folder-"), ref.url != navigation.folder { return .gone(id) }
            return ContextLocation(
                id: id, state: .visible, rects: [ContextGeometry.global(window.frame)], window: window.windowNumber
            )
        }
        guard let url = ref.url else { return .gone(id) }
        let snapshot = navigation.snapshot
        guard snapshot.folders.contains(where: { $0.url == url }) || snapshot.notes.contains(where: { $0.url == url })
        else { return .gone(id) }
        guard let frame = navigation.screenFrame(of: url) else {
            return ContextLocation(id: id, state: .offscreen, window: window.windowNumber)
        }
        return ContextLocation(
            id: id, state: .visible, rects: [ContextGeometry.global(frame)], window: window.windowNumber
        )
    }

    private func id(_ kind: String, _ navigation: LibraryNavigation, _ url: URL?) -> String {
        let key = "\(kind)|\(ObjectIdentifier(navigation).hashValue)|\(url?.path ?? "")"
        if let id = known[key], issued[id]?.navigation != nil { return id }
        counter += 1
        let id = "\(kind)-\(counter)"
        issued[id] = Ref(navigation, url)
        known[key] = id
        return id
    }
}
