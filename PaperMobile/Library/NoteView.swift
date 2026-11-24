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
    @State private var failure: String?
    @State private var pendingSave: Task<Void, Never>?

    var body: some View {
        Group {
            if let failure {
                Text(failure)
                    .foregroundStyle(.secondary)
                    .padding()
            } else if loaded {
                MobileEditor(text: $text, fileURL: url)
                    // The page runs under the navigation bar and the
                    // keyboard so text scrolls beneath both bars and fades
                    // there; the text view insets itself.
                    .ignoresSafeArea()
            }
        }
        .background(Color(uiColor: Appearance.canvas).ignoresSafeArea())
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
        guard loaded, text != saved else { return }
        do {
            try NoteFile.write(text, to: url)
            saved = text
        } catch {
            failure = "This note couldn’t be saved: \(error.localizedDescription)"
        }
    }
}
