import Foundation

/// The pinned documents, in the order pinned: the list the menu bar item
/// shows (#77). A value, so the file format and the edits are testable
/// without a store; `PinStore` keeps the live one and writes it out.
struct Pins: Equatable, Sendable {
    /// One pinned document: its file and, if given, the name it goes by
    /// in the bar instead of the file name.
    struct Pin: Equatable, Sendable {
        let url: URL
        var name: String?

        /// What the bar shows: the given name, or the file name.
        var title: String { name ?? url.lastPathComponent }
    }

    /// Oldest pin first, no duplicate files.
    private(set) var pins: [Pin] = []

    /// The pinned files, in order.
    var urls: [URL] { pins.map(\.url) }

    init(_ urls: [URL] = []) {
        for url in urls { append(url) }
    }

    /// The file's shape: `{"pins": [{"path": "/abs/path", "name": "Today"}, …]}`,
    /// `name` optional; a bare string in place of an object is a path, the
    /// first release's form. Anything else, a missing file included, is
    /// no pins; a bad entry is skipped rather than sinking the list.
    static func decode(_ data: Data) -> Pins {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["pins"] as? [Any] else { return Pins() }
        var pins = Pins()
        for entry in entries {
            if let path = entry as? String {
                pins.append(URL(fileURLWithPath: path))
            } else if let record = entry as? [String: Any], let path = record["path"] as? String {
                pins.append(URL(fileURLWithPath: path))
                pins.rename(URL(fileURLWithPath: path), to: record["name"] as? String)
            }
        }
        return pins
    }

    func encoded() -> Data {
        let entries: [[String: Any]] = pins.map { pin in
            var record: [String: Any] = ["path": pin.url.path]
            if let name = pin.name { record["name"] = name }
            return record
        }
        let object: [String: Any] = ["pins": entries]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    func contains(_ url: URL) -> Bool {
        index(of: url) != nil
    }

    func pin(for url: URL) -> Pin? {
        index(of: url).map { pins[$0] }
    }

    /// Pins an unpinned document at the end, or unpins a pinned one.
    mutating func toggle(_ url: URL) {
        if contains(url) { remove(url) } else { append(url) }
    }

    mutating func remove(_ url: URL) {
        pins.removeAll { $0.url == url.standardizedFileURL }
    }

    /// Names a pin, or with nil or a blank name returns it to the file name.
    mutating func rename(_ url: URL, to name: String?) {
        guard let index = index(of: url) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        pins[index].name = trimmed.isEmpty ? nil : trimmed
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        pins.move(fromOffsets: source, toOffset: destination)
    }

    private func index(of url: URL) -> Int? {
        let standardized = url.standardizedFileURL
        return pins.firstIndex { $0.url == standardized }
    }

    private mutating func append(_ url: URL) {
        guard !contains(url) else { return }
        pins.append(Pin(url: url.standardizedFileURL, name: nil))
    }
}

/// What the menu bar item lists for the pins: each with its title and
/// whether the file is there. A missing file stays in place, dimmed, so
/// a document on another branch or an unmounted drive is not forgotten.
enum MenuBarModel {
    struct Entry: Equatable, Sendable {
        let url: URL
        /// The pin's name, or the file name.
        let name: String
        let missing: Bool
    }

    static func pinned(
        _ pins: Pins,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [Entry] {
        pins.pins.map { Entry(url: $0.url, name: $0.title, missing: !exists($0.url)) }
    }
}
