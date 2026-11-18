import Foundation
import Testing
@testable import Paper

/// The watcher reports external writes, including atomic saves that
/// replace the file's inode.
@MainActor
struct FileWatcherTests {
    private func temporaryFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString).md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func waitForChange(_ fired: () -> Bool) async throws {
        for _ in 0..<100 where !fired() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test
    func reportsAPlainWrite() async throws {
        let url = try temporaryFile("one")
        defer { try? FileManager.default.removeItem(at: url) }
        var fired = false
        let watcher = FileWatcher(url: url) { fired = true }
        defer { watcher.cancel() }

        try Data("two".utf8).write(to: url)
        try await waitForChange { fired }
        #expect(fired)
    }

    @Test
    func reportsAnAtomicReplacementAndKeepsWatching() async throws {
        let url = try temporaryFile("one")
        defer { try? FileManager.default.removeItem(at: url) }
        var changes = 0
        let watcher = FileWatcher(url: url) { changes += 1 }
        defer { watcher.cancel() }

        // An atomic save: write elsewhere, rename over the watched path —
        // the inode the watcher opened is gone.
        try "two".write(to: url, atomically: true, encoding: .utf8)
        try await waitForChange { changes >= 1 }
        #expect(changes >= 1)

        // The re-armed watcher still sees the next save.
        let before = changes
        try await Task.sleep(for: .milliseconds(200))
        try "three".write(to: url, atomically: true, encoding: .utf8)
        try await waitForChange { changes > before }
        #expect(changes > before)
    }

    @Test
    func reportsAFileThatAppearsAfterWatchingBegan() async throws {
        // An image referenced before it is written: the watcher starts on
        // a missing path, re-arms until the file exists, and reports its
        // appearance even though the write predates the descriptor.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        var fired = false
        let watcher = FileWatcher(url: url) { fired = true }
        defer { watcher.cancel() }

        try await Task.sleep(for: .milliseconds(150))
        #expect(!fired)
        try Data("pixels".utf8).write(to: url)
        try await waitForChange { fired }
        #expect(fired)
    }

    @Test
    func cancelStopsReports() async throws {
        let url = try temporaryFile("one")
        defer { try? FileManager.default.removeItem(at: url) }
        var fired = false
        let watcher = FileWatcher(url: url) { fired = true }
        watcher.cancel()

        try Data("two".utf8).write(to: url)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!fired)
    }
}
