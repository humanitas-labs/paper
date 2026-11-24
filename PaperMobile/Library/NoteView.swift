import SwiftUI

/// A note opened from the library: read once, written back a moment after
/// each pause in typing and when the note closes or the app leaves the
/// foreground.
struct NoteView: View {
    let url: URL
    @ObservedObject private var store = ConfigurationStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @State private var saved = ""
    @State private var loaded = false
    /// An empty note opens on a title line, `# ` with the caret after it,
    /// as Notes starts on its title. Left untouched, it saves as empty.
    @State private var startsWithTitle = false
    private static let titleLine = "# "
    @State private var failure: String?
    @State private var pendingSave: Task<Void, Never>?

    var body: some View {
        // A ZStack over the canvas, not a Group: an empty Group has no
        // view, so its `task` never runs and the note never loads.
        ZStack {
            Color(uiColor: Appearance.canvas).ignoresSafeArea()
            if let failure {
                Text(failure)
                    .foregroundStyle(.secondary)
                    .padding()
            } else if loaded {
                MobileEditor(text: $text, fileURL: url, focusesEnd: startsWithTitle)
                    // The page runs under the navigation bar and the
                    // keyboard so text scrolls beneath both bars and fades
                    // there; the text view insets itself.
                    .ignoresSafeArea()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: url)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: url) { load() }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { save() }
        }
        .onDisappear { save() }
    }

    private func load() {
        do {
            text = try NoteFile.read(url)
            saved = text
            if text.isEmpty {
                text = Self.titleLine
                startsWithTitle = true
            }
            loaded = true
        } catch {
            failure = "This note couldn’t be opened: \(error.localizedDescription)"
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        let content = text == Self.titleLine ? "" : text
        guard loaded, content != saved else { return }
        do {
            try NoteFile.write(content, to: url)
            saved = content
        } catch {
            failure = "This note couldn’t be saved: \(error.localizedDescription)"
        }
    }
}
