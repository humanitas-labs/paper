import Foundation

/// Watches one file for writes by other programs and reports them on the
/// main actor, debounced. Most editors save atomically by replacing the
/// inode, so delete and rename events re-open the path and keep watching
/// the new file. A path that cannot be opened yet is retried until it can,
/// and the file's appearance is reported like a write.
@MainActor
final class FileWatcher {
    static let debounce: TimeInterval = 0.1
    static let rearmDelay: TimeInterval = 0.05
    /// A path that stays missing re-arms slower each try, up to this.
    static let rearmCeiling: TimeInterval = 2.0

    private let url: URL
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pendingChange: Task<Void, Never>?
    private var cancelled = false
    private var missedOpens = 0

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
        watch()
    }

    /// Stops watching and closes the file descriptor. Must be called before
    /// the watcher is released; there is no isolated deinit to do it.
    func cancel() {
        cancelled = true
        pendingChange?.cancel()
        pendingChange = nil
        source?.cancel()
        source = nil
    }

    private func watch() {
        guard !cancelled else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // Mid-replace the path can briefly not exist; try again shortly.
            // A file that stays gone (deleted, unmounted, not yet written)
            // must not spin the main queue every 50 ms forever, so each
            // miss doubles the wait up to the ceiling; the next successful
            // open resets it.
            let delay = min(Self.rearmDelay * pow(2, Double(missedOpens)), Self.rearmCeiling)
            missedOpens += 1
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.watch()
            }
            return
        }
        // A path that could not be opened and now can is a file that
        // appeared, or was replaced, between looks: its contents were
        // written before this descriptor existed, so no event will ever
        // report them. Report the appearance ourselves.
        let appeared = missedOpens > 0
        missedOpens = 0
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.handleEvent() }
        }
        source.setCancelHandler { close(descriptor) }
        source.activate()
        self.source = source
        if appeared { scheduleChange() }
    }

    private func scheduleChange() {
        pendingChange?.cancel()
        pendingChange = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.debounce))
            guard !Task.isCancelled, let self, !self.cancelled else { return }
            self.onChange()
        }
    }

    private func handleEvent() {
        guard let source, !cancelled else { return }
        if !source.data.intersection([.delete, .rename]).isEmpty {
            source.cancel()
            self.source = nil
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.rearmDelay))
                self?.watch()
            }
        }
        scheduleChange()
    }
}
