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
    /// produced in a temporary folder and moved into place, so a failure
    /// leaves whatever was there.
    ///
    /// The print operation must never be handed a path it cannot write: a
    /// save job that fails to open its file goes to the default printer
    /// instead. So the destination's folder is checked first, and the
    /// operation only ever writes into a folder made here.
    /// `style` sets the page; nil is the configured default.
    static func export(
        text: String, documentURL: URL?, to destination: URL, paper: Paper = .default, style: PrintStyle? = nil
    ) throws {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path, isDirectory: &isFolder),
              isFolder.boolValue else {
            throw Failure.write(destination)
        }
        let stagingFolder: URL
        do {
            stagingFolder = try makeStagingFolder(for: destination)
        } catch {
            throw Failure.write(destination)
        }
        defer { try? FileManager.default.removeItem(at: stagingFolder) }
        let staging = stagingFolder.appendingPathComponent("export.pdf")
        try inStyle(style ?? ConfigurationStore.shared.defaultPrintStyle) { style in
            let size = style.page.pageSize ?? paper.size
            let textView = makeSurface(text: text, documentURL: documentURL, size: size, style: style)
            let owner = ObjectIdentifier(textView)
            defer { ImageStore.shared.removeDemand(for: owner) }
            try pinImages(of: textView, owner: owner)
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            textView.sizeToFit()

            let info = printInfo(for: size, saving: staging)
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

    /// Runs `body` at zoom 1 with the style's config and colors standing in
    /// for the store's, so the surface is styled and drawn in the style.
    private static func inStyle<T>(_ style: PrintStyle, _ body: (PrintStyle) throws -> T) rethrows -> T {
        let appearance = ConfigurationStore.shared.printAppearance(for: style)
        return try Appearance.withConfiguration(appearance.configuration, palette: appearance.palette) {
            try Zoom.withScale(1) { try body(style) }
        }
    }

    /// A new, empty folder for the print operation's file: on the
    /// destination's volume when the system has one to give, so the move
    /// into place is a rename, in the temporary directory otherwise.
    private static func makeStagingFolder(for destination: URL) throws -> URL {
        if let folder = try? FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true
        ) {
            return folder
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("paper-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The body type on the page, whatever size it reads at on screen,
    /// and the text's distance from every page edge: `print.font.size`
    /// and `print.margin` in the config.
    static var bodySizeOnPage: CGFloat { CGFloat(Appearance.configuration.printFontSize) }
    static var pageMargin: CGFloat { CGFloat(Appearance.configuration.printMargin) }

    /// The page's scale: the on-screen body brought to `bodySizeOnPage`.
    private static var scale: CGFloat { bodySizeOnPage / Appearance.bodySize }

    /// How a page's margins are made. The side margin is split between the
    /// sheet's own margin (`side`, in page points) and the text view's
    /// inset (`inset`, in the view's points), which leaves room for quote
    /// rules and code bands inside the view. The print system moves a
    /// sheet margin smaller than the printer's unprintable edge out to that
    /// edge, and only on the left, since the view is clipped on the right:
    /// a side of 0 pushed the column right by the edge's width. So the side
    /// never goes under the edge, and the inset shrinks to keep the margin
    /// as set. Top and bottom are the margin, or the edge when it is wider.
    struct Margins: Equatable {
        let side: CGFloat
        let inset: CGFloat
        let top: CGFloat
        let bottom: CGFloat
    }

    static func margins(for size: NSSize) -> Margins {
        let edges = unprintableEdges(for: size)
        let floor = max(edges.left, edges.right)
        let fullInset = Appearance.minimumHorizontalMargin * scale
        let side = max(pageMargin - fullInset, floor)
        let insetOnPage = max(pageMargin - side, 0)
        return Margins(
            side: side, inset: insetOnPage / scale,
            top: max(pageMargin, edges.top), bottom: max(pageMargin, edges.bottom)
        )
    }

    /// The printer's unprintable edges for a sheet of `size`, from the
    /// imageable bounds the print system reports for it; zero when it
    /// reports none.
    private static func unprintableEdges(for size: NSSize) -> NSEdgeInsets {
        let info = NSPrintInfo()
        info.paperSize = size
        let bounds = info.imageablePageBounds
        guard bounds.width > 0, bounds.height > 0 else { return NSEdgeInsetsZero }
        return NSEdgeInsets(
            top: max(size.height - bounds.maxY, 0), left: max(bounds.minX, 0),
            bottom: max(bounds.minY, 0), right: max(size.width - bounds.maxX, 0)
        )
    }

    /// The column that fills the page between its margins at that scale,
    /// with the view's inset around it (see `Margins`); no window, so no
    /// title band, and no selection, so every marker is concealed.
    private static func makeSurface(text: String, documentURL: URL?, size: NSSize, style: PrintStyle) -> PaperTextView {
        let textView = PaperTextView()
        textView.isPrintSurface = true
        textView.printPage = style.page
        let margins = margins(for: size)
        textView.printHorizontalInset = margins.inset
        let measure = (size.width - 2 * (margins.side + margins.inset * scale)) / scale
        let width = measure + 2 * margins.inset
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        textView.documentURL = documentURL
        textView.string = text
        textView.syntaxStyler.apply(to: textView)
        annotateLinks(in: textView)
        return textView
    }

    /// AppKit writes a URL rectangle into the PDF for every run carrying
    /// its own link attribute, so each link's visible text gets one over
    /// the styler's destination, resolved the way a click resolves it.
    /// Fragments name headings in this document; the PDF has no anchor
    /// for them, so they are left unlinked. The screen view never carries
    /// the attribute; it handles clicks itself.
    private static func annotateLinks(in textView: PaperTextView) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.linkDestination, in: whole) { value, range, _ in
            guard let destination = value as? String, !destination.hasPrefix("#"),
                  let url = textView.linkURL(for: destination) else { return }
            storage.addAttribute(.link, value: url, range: range)
        }
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

    private static func printInfo(for size: NSSize, saving url: URL) -> NSPrintInfo {
        let info = NSPrintInfo()
        configure(info, for: size)
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        return info
    }

    /// The column scaled so the body lands at `bodySizeOnPage`; the view's
    /// own side margins are part of the page margin.
    private static func configure(_ info: NSPrintInfo, for size: NSSize) {
        info.paperSize = size
        info.orientation = .portrait
        info.scalingFactor = scale
        let margins = margins(for: size)
        info.leftMargin = margins.side
        info.rightMargin = margins.side
        info.topMargin = margins.top
        info.bottomMargin = margins.bottom
        info.horizontalPagination = .clip
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
    }

    // MARK: - File ▸ Print…

    /// The print panel over the same surface the export paginates, so a
    /// printed page and an exported one are the same page. The panel's
    /// own PDF button works too. App-modal, as the images stay pinned
    /// only for the length of the call. The page is in the configured
    /// default style.
    static func print(_ textView: PaperTextView) {
        inStyle(ConfigurationStore.shared.defaultPrintStyle) { style in
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            let paper = abs(info.paperSize.width - Paper.a4.size.width) < 1 ? Paper.a4 : .letter
            let size = style.page.pageSize ?? paper.size
            let surface = makeSurface(text: textView.string, documentURL: textView.documentURL, size: size, style: style)
            let owner = ObjectIdentifier(surface)
            defer { ImageStore.shared.removeDemand(for: owner) }
            try? pinImages(of: surface, owner: owner)
            surface.layoutManager?.ensureLayout(for: surface.textContainer!)
            surface.sizeToFit()

            configure(info, for: size)
            let operation = NSPrintOperation(view: surface, printInfo: info)
            operation.jobTitle = textView.printJobTitle
            operation.showsPrintPanel = true
            operation.showsProgressPanel = true
            operation.run()
        }
    }

    // MARK: - Save panel

    /// The save panel as a sheet on the view's window, paper and style
    /// pickers in its accessory, the document's name proposed. A failure is reported
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
                try export(text: text, documentURL: documentURL, to: url, paper: picker.paper, style: picker.style)
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

    /// "Paper Size: [Letter ▾]  Style: [Paper ▾]" for the save panel. The
    /// styles are read when the panel opens; the configured one is chosen.
    private final class PaperPicker: NSView {
        private let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        private let stylePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        private let styles = ConfigurationStore.shared.printStyles()

        var paper: Paper {
            Paper.allCases[max(0, popUp.indexOfSelectedItem)]
        }

        var style: PrintStyle {
            styles.indices.contains(stylePopUp.indexOfSelectedItem) ? styles[stylePopUp.indexOfSelectedItem] : .paper
        }

        init() {
            super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 40))
            let label = NSTextField(labelWithString: "Paper Size:")
            popUp.addItems(withTitles: Paper.allCases.map(\.rawValue))
            popUp.selectItem(at: Paper.allCases.firstIndex(of: .default) ?? 0)
            let styleLabel = NSTextField(labelWithString: "Style:")
            stylePopUp.addItems(withTitles: styles.map { $0.name.prefix(1).uppercased() + $0.name.dropFirst() })
            let chosen = ConfigurationStore.shared.defaultPrintStyle.name
            stylePopUp.selectItem(at: styles.firstIndex { $0.name == chosen } ?? 0)
            let stack = NSStackView(views: [label, popUp, styleLabel, stylePopUp])
            stack.setCustomSpacing(20, after: popUp)
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
