import AppKit
import SwiftUI

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    /// The document's file, so relative links and images resolve; nil
    /// until the first save.
    var fileURL: URL? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = PaperScrollView()
        let textView = PaperTextView()

        textView.delegate = context.coordinator
        textView.documentURL = fileURL
        textView.string = text
        textView.syntaxStyler.apply(to: textView)

        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Appearance.canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .legacy
        // Under the full-size content view AppKit would inset the content
        // and the scroller by the title area; the text view carries that
        // band in its top margin instead, so the track runs corner to
        // corner and the top of the document is scroll position zero (#61).
        scrollView.automaticallyAdjustsContentInsets = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PaperTextView else { return }

        context.coordinator.text = $text
        textView.documentURL = fileURL

        guard textView.string != text else { return }
        let selection = textView.selectedRange()
        textView.string = text
        textView.syntaxStyler.apply(to: textView)
        textView.setSelectedRange(selection.clamped(to: text.utf16.count))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? PaperTextView else { return }
            text.wrappedValue = textView.string
            // Restyling replaces attributes in the storage. During
            // input-method composition that discards marked text, so styling
            // waits until the composition commits and fires a final change.
            guard !textView.hasMarkedText() else { return }
            textView.syntaxStyler.applyEdited(to: textView)
        }
    }
}

extension NSRange {
    /// Clamps the range into `0...utf16Length` so a selection survives an
    /// external replacement of the text it referred to.
    func clamped(to utf16Length: Int) -> NSRange {
        let safeLocation = min(location, utf16Length)
        let availableLength = utf16Length - safeLocation
        return NSRange(location: safeLocation, length: min(length, availableLength))
    }
}

