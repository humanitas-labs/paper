import AppKit

/// The dialog that pins a document: the name it will go by in the menu
/// bar, the file name to start, so a pin is named as it is made rather
/// than found later. Rename runs the same dialog on a pin that exists.
@MainActor
enum PinPrompt {
    /// Pins the file under the name entered; Cancel pins nothing.
    static func pin(_ url: URL, store: PinStore = .shared) {
        guard !store.pins.contains(url) else { return }
        guard let name = ask(title: "Pin \(url.lastPathComponent)", button: "Pin", current: url.lastPathComponent, for: url) else { return }
        store.toggle(url)
        store.rename(url, to: name)
    }

    static func rename(_ url: URL, store: PinStore = .shared) {
        guard let pin = store.pins.pin(for: url) else { return }
        guard let name = ask(title: "Rename \(pin.title)", button: "Rename", current: pin.title, for: url) else { return }
        store.rename(url, to: name)
    }

    /// The name entered, nil on Cancel. A name that is the file name is
    /// handed back empty, so the pin falls back to the file name and follows
    /// a rename of the file.
    private static func ask(title: String, button: String, current: String, for url: URL) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "The name shown in the menu bar."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current
        field.placeholderString = url.lastPathComponent
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        field.selectText(nil)
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name == url.lastPathComponent ? "" : name
    }
}
