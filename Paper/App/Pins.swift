import Foundation

/// The pinned documents, in the order pinned: the list the menu bar item
/// shows (#77). A value, so the file format and the edits are testable
/// without a store; `PinStore` keeps the live one and writes it out.
struct Pins: Equatable, Sendable {
    /// Standardized file URLs, oldest pin first, no duplicates.
    private(set) var urls: [URL] = []

    init(_ urls: [URL] = []) {
        for url in urls { append(url) }
    }

    /// The file's shape: `{"pins": ["/abs/path", …]}`. Anything that is
    /// not that, a missing file included, is no pins; a bad entry is
    /// skipped rather than sinking the list.
    static func decode(_ data: Data) -> Pins {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = object["pins"] as? [String] else { return Pins() }
        return Pins(paths.map { URL(fileURLWithPath: $0) })
    }

    func encoded() -> Data {
        let object: [String: Any] = ["pins": urls.map(\.path)]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    func contains(_ url: URL) -> Bool {
        urls.contains(url.standardizedFileURL)
    }

    /// Pins an unpinned document at the end, or unpins a pinned one.
    mutating func toggle(_ url: URL) {
        if contains(url) { remove(url) } else { append(url) }
    }

    mutating func remove(_ url: URL) {
        urls.removeAll { $0 == url.standardizedFileURL }
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        urls.move(fromOffsets: source, toOffset: destination)
    }

    private mutating func append(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard !urls.contains(standardized) else { return }
        urls.append(standardized)
    }
}

/// What the menu bar item lists for the pins: each with its name and
/// whether the file is there. A missing file stays in place, dimmed, so
/// a document on another branch or an unmounted drive is not forgotten.
enum MenuBarModel {
    struct Entry: Equatable, Sendable {
        let url: URL
        let name: String
        let missing: Bool
    }

    static func pinned(
        _ pins: Pins,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [Entry] {
        pins.urls.map { Entry(url: $0, name: $0.lastPathComponent, missing: !exists($0)) }
    }
}
