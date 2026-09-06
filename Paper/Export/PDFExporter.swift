import AppKit
import UniformTypeIdentifiers

/// The document as Paper draws it, paginated onto Letter or A4.
///
/// An offscreen `PaperTextView` is styled at zoom 1 with a measure derived
/// from the page (the configured print body size between print margins),
/// every image band pinned and decoded, no active paragraph and no
/// selection, then handed to an `NSPrintOperation` with a save job. AppKit breaks pages between line fragments (an image band is
/// part of its paragraph's fragment, so it moves whole); the view's own
/// `drawBackground` puts the code bands, quote rules, breaks, task circles,
/// and images on each page. The column is scaled so the body type lands
/// at 11 pt and centred, so the wrapping is the screen's.
@MainActor
enum PDFExporter {
    enum Paper: String, CaseIterable {
        case letter = "Letter"
        case a4 = "A4"

        var size: NSSize {
            switch self {
            case .letter: NSSize(width: 612, height: 792)
            case .a4: NSSize(width: 595.276, height: 841.89)
            }
        }

        /// The system's default paper, by width: A4 where the locale sets
        /// it, Letter otherwise.
        static var `default`: Paper {
            abs(NSPrintInfo.shared.paperSize.width - Paper.a4.size.width) < 1 ? .a4 : .letter
        }
    }

    enum Failure: LocalizedError {
        case image(URL)
        case write(URL)

        var errorDescription: String? {
            switch self {
            case .image(let url): "The image \(url.path) could not be read."
            case .write(let url): "The PDF could not be written to \(url.path)."
            }
        }
    }

    /// Writes `text` as a PDF at `destination`. `documentURL` resolves
    /// relative image and link paths, as it does on screen. The file is
    /// produced beside the destination and moved into place, so a failure
    /// leaves whatever was there.
    static func export(text: String, documentURL: URL?, to destination: URL, paper: Paper = .default) throws {
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try Zoom.withScale(1) {
            let textView = makeSurface(text: text, documentURL: documentURL, paper: paper)
            let owner = ObjectIdentifier(textView)
            defer { ImageStore.shared.removeDemand(for: owner) }
            try pinImages(of: textView, owner: owner)
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            textView.sizeToFit()

            let info = printInfo(for: paper, saving: staging)
            let operation = NSPrintOperation(view: textView, printInfo: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            guard operation.run(), FileManager.default.fileExists(atPath: staging.path) else {
                throw Failure.write(destination)
            }
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            throw Failure.write(destination)
        }
    }

    /// The body type on the page, whatever size it reads at on screen,
    /// and the text's distance from every page edge: `print.font.size`
    /// and `print.margin` in the config.
    static var bodySizeOnPage: CGFloat { CGFloat(Appearance.configuration.printFontSize) }
    static var pageMargin: CGFloat { CGFloat(Appearance.configuration.printMargin) }

    /// The page's scale: the on-screen body brought to `bodySizeOnPage`.
    private static var scale: CGFloat { bodySizeOnPage / Appearance.bodySize }

    /// The margin as set, or the view's own side inset at the page's scale
    /// when that is wider: the inset is part of the margin, never past it.
    private static var effectiveMargin: CGFloat {
        max(pageMargin, Appearance.minimumHorizontalMargin * scale)
    }

    /// The column that fills the page between its margins at that scale,
    /// with Paper's minimum side margins around it (the quote rules and
    /// code bands need them); no window, so no title band, and no
    /// selection, so every marker is concealed.
    private static func makeSurface(text: String, documentURL: URL?, paper: Paper) -> PaperTextView {
        let textView = PaperTextView()
        textView.isPrintSurface = true
        let measure = (paper.size.width - 2 * effectiveMargin) / scale
        let width = measure + 2 * Appearance.minimumHorizontalMargin
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        textView.documentURL = documentURL
        textView.string = text
        textView.syntaxStyler.apply(to: textView)
        return textView
    }

    /// Every band's file, pinned against eviction for the length of the
    /// export and decoded now: drawing only looks in the cache. A file
    /// that is missing has no band (its alt text shows, as on screen);
    /// one with a band that will not decode fails the export.
    private static func pinImages(of textView: PaperTextView, owner: ObjectIdentifier) throws {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        var urls: [URL] = []
        storage.enumerateAttribute(.imageSource, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let url = value as? URL, !urls.contains(url) { urls.append(url) }
        }
        guard !urls.isEmpty else { return }
        ImageStore.shared.updateDemand(for: owner, visible: urls, prefetch: [])
        for url in urls where ImageStore.shared.entry(for: url) == nil {
            throw Failure.image(url)
        }
    }

    private static func printInfo(for paper: Paper, saving url: URL) -> NSPrintInfo {
        let info = NSPrintInfo()
        configure(info, for: paper)
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        return info
    }

    /// The column scaled so the body lands at `bodySizeOnPage`; the view's
    /// own side margins are part of the page margin.
    private static func configure(_ info: NSPrintInfo, for paper: Paper) {
        info.paperSize = paper.size
        info.orientation = .portrait
        info.scalingFactor = scale
        let side = effectiveMargin - Appearance.minimumHorizontalMargin * scale
        info.leftMargin = side
        info.rightMargin = side
        info.topMargin = effectiveMargin
        info.bottomMargin = effectiveMargin
        info.horizontalPagination = .clip
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
    }

    // MARK: - File ▸ Print…

    /// The print panel over the same surface the export paginates, so a
    /// printed page and an exported one are the same page. The panel's
    /// own PDF button works too. App-modal, as the images stay pinned
    /// only for the length of the call.
    static func print(_ textView: PaperTextView) {
        Zoom.withScale(1) {
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            let paper = abs(info.paperSize.width - Paper.a4.size.width) < 1 ? Paper.a4 : .letter
            let surface = makeSurface(text: textView.string, documentURL: textView.documentURL, paper: paper)
            let owner = ObjectIdentifier(surface)
            defer { ImageStore.shared.removeDemand(for: owner) }
            try? pinImages(of: surface, owner: owner)
            surface.layoutManager?.ensureLayout(for: surface.textContainer!)
            surface.sizeToFit()

            configure(info, for: paper)
            let operation = NSPrintOperation(view: surface, printInfo: info)
            operation.jobTitle = textView.printJobTitle
            operation.showsPrintPanel = true
            operation.showsProgressPanel = true
            operation.run()
        }
    }

    // MARK: - Save panel

    /// The save panel as a sheet on the view's window, a paper picker in
    /// its accessory, the document's name proposed. A failure is reported
    /// on the same window.
    static func present(for textView: PaperTextView) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = textView.printJobTitle + ".pdf"
        if let folder = textView.documentURL?.deletingLastPathComponent() {
            panel.directoryURL = folder
        }
        let picker = PaperPicker()
        panel.accessoryView = picker

        let text = textView.string
        let documentURL = textView.documentURL
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try export(text: text, documentURL: documentURL, to: url, paper: picker.paper)
            } catch {
                let alert = NSAlert()
                alert.messageText = "The PDF was not exported."
                alert.informativeText = error.localizedDescription
                if let window = textView.window {
                    alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
            }
        }
        if let window = textView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// "Paper Size: [Letter ▾]" for the save panel.
    private final class PaperPicker: NSView {
        private let popUp = NSPopUpButton(frame: .zero, pullsDown: false)

        var paper: Paper {
            Paper.allCases[max(0, popUp.indexOfSelectedItem)]
        }

        init() {
            super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
            let label = NSTextField(labelWithString: "Paper Size:")
            popUp.addItems(withTitles: Paper.allCases.map(\.rawValue))
            popUp.selectItem(at: Paper.allCases.firstIndex(of: .default) ?? 0)
            let stack = NSStackView(views: [label, popUp])
            stack.orientation = .horizontal
            stack.alignment = .firstBaseline
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }
    }
}
