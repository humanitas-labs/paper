import SwiftUI

@main
struct PaperMobileApp: App {
    init() {
        ConfigurationStore.shared.start()
    }

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { configuration in
            MobileDocumentView(document: configuration.$document, fileURL: configuration.fileURL)
        }
    }
}

private struct MobileDocumentView: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?
    /// Observed so the canvas follows theme changes.
    @ObservedObject private var store = ConfigurationStore.shared

    var body: some View {
        MobileEditor(text: $document.text, fileURL: fileURL)
            .ignoresSafeArea(.container, edges: .bottom)
            .background(Color(uiColor: Appearance.canvas))
    }
}

/// Bridges the SwiftUI document binding into the UIKit page, as
/// `MarkdownEditor` does on the Mac.
struct MobileEditor: UIViewRepresentable {
    @Binding var text: String
    var fileURL: URL?

    func makeUIView(context: Context) -> MobileTextView {
        let textView = MobileTextView()
        textView.documentURL = fileURL
        textView.load(text)
        return textView
    }

    func updateUIView(_ textView: MobileTextView, context: Context) {
        textView.documentURL = fileURL
        guard textView.text != text else { return }
        textView.load(text)
    }
}
