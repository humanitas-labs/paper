import Foundation

/// Owns the live pins and the file behind them: Paper's own state in
/// Application Support, so it survives an update (#72) and a config
/// reset. Read once at start, written whole on every change; nobody edits
/// it by hand, so it is not watched.
@MainActor
final class PinStore: ObservableObject {
    static let shared = PinStore(fileURL: defaultFileURL)

    /// `~/Library/Application Support/Paper/state.json`. Named for what it
    /// holds rather than for the pins, so later state (recents, #72) can
    /// share the file.
    static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Paper", isDirectory: true).appendingPathComponent("state.json")
    }

    @Published private(set) var pins = Pins()
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads the file; nothing there is no pins. Safe to call more than once.
    func start() {
        pins = (try? Data(contentsOf: fileURL)).map(Pins.decode) ?? Pins()
    }

    func toggle(_ url: URL) {
        var next = pins
        next.toggle(url)
        write(next)
    }

    func remove(_ url: URL) {
        var next = pins
        next.remove(url)
        write(next)
    }

    func rename(_ url: URL, to name: String?) {
        var next = pins
        next.rename(url, to: name)
        write(next)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var next = pins
        next.move(fromOffsets: source, toOffset: destination)
        write(next)
    }

    private func write(_ next: Pins) {
        guard next != pins else { return }
        pins = next
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? next.encoded().write(to: fileURL, options: .atomic)
    }
}
