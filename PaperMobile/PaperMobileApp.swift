import SwiftUI

@main
struct PaperMobileApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
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
        textView.onTextChange = { text = $0 }
        return textView
    }

    func updateUIView(_ textView: MobileTextView, context: Context) {
        textView.documentURL = fileURL
        textView.onTextChange = { text = $0 }
        guard textView.text != text else { return }
        textView.load(text)
    }
}

/// Loads the configuration at launch, before any scene. Loading it in the
/// `App` initializer publishes the store's values while SwiftUI is still
/// building the scene, which it reports as a change during a view update.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        ConfigurationStore.shared.start()
        return true
    }
}
