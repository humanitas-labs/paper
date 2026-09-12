import SwiftUI

/// The front document's file, put up by `DocumentView` for the File menu:
/// nil for an untitled document, and absent when no document is front.
struct DocumentURLKey: FocusedValueKey {
    typealias Value = URL?
}

extension FocusedValues {
    var documentURL: URL?? {
        get { self[DocumentURLKey.self] }
        set { self[DocumentURLKey.self] = newValue }
    }
}

/// File ▸ Pin Document / Unpin Document (⇧⌘P), for the menu bar item
/// (#77). The title follows the front document and the pins, so it reads
/// as the thing it will do; nothing to pin disables it.
struct PinCommands: Commands {
    @FocusedValue(\.documentURL) private var documentURL
    @ObservedObject private var pins = PinStore.shared

    private var url: URL? { documentURL ?? nil }

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Divider()
            // Pinning asks for the name first; unpinning is one step.
            Button(url.map(pins.pins.contains) == true ? "Unpin Document" : "Pin Document…") {
                guard let url else { return }
                if pins.pins.contains(url) { pins.toggle(url) } else { PinPrompt.pin(url) }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(url == nil)
        }
    }
}
