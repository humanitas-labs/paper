import AppKit

/// Miniatures of notes for the library's cards, drawn by Paper's own editor
/// offscreen at a page's width and kept for as long as the note, the
/// appearance and the settings are unchanged. The iPhone draws its cards
/// the same way with its own editor.
@MainActor
enum NoteMiniature {
    /// The card's shape: a page a little taller than three by four, the
    /// proportion of Spatial's note card, 235 by 334.
    static let aspect: CGFloat = 235.0 / 334.0
    /// Wide enough that a card shows the note's head at a legible scale.
    static let pageWidth: CGFloat = 460
    /// Only the head of a long note can show.
    static let characterLimit = 2400
    /// The page's margins inside the card: enough to breathe, little
    /// enough that the text fills the card.
    static let margins = NSSize(width: 24, height: 28)
    /// Enough miniatures for a few full folders; the oldest go first.
    static let cacheLimit = 400

    struct Key: Hashable {
        let url: URL
        let modified: Date
        let dark: Bool
        /// Bumped by any settings change, which may change the theme, the
        /// fonts or the zoom.
        let generation: Int
    }

    private static var cache: [Key: NSImage] = [:]
    private static var order: [Key] = []
    private static var generation = 0
    private static var observer: NSObjectProtocol?

    static func key(for url: URL, modified: Date, dark: Bool) -> Key {
        startObserving()
        return Key(url: url.standardizedFileURL, modified: modified, dark: dark, generation: generation)
    }

    static func cached(_ key: Key) -> NSImage? { cache[key] }

    /// The card's image, drawn now if it is not cached. `background` is
    /// the card's color, so the page and the card are one surface.
    static func image(for url: URL, modified: Date, dark: Bool, background: NSColor) -> NSImage? {
        let key = key(for: url, modified: modified, dark: dark)
        if let cached = cache[key] { return cached }
        // Read plainly, not through file coordination: this runs on the
        // main thread, and a coordinated read there waits behind any move
        // or save of the note, which itself waits on the main thread, and
        // the app hangs. A preview read mid-save is redrawn when the save
        // lands.
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let image = thumbnail(render(String(text.prefix(characterLimit)), documentURL: url, dark: dark, background: background))
        store(image, for: key)
        return image
    }

    /// The page at the size a card shows it. A card is at most 210 pt
    /// wide, 420 pixels on a Retina screen; the page is drawn at 920, and
    /// a grid of those costs four times the memory and scales every one
    /// of them on every frame of a scroll.
    static let thumbnailPixels = 460

    static func thumbnail(_ page: NSImage) -> NSImage {
        guard let source = page.representations.first as? NSBitmapImageRep, let cgImage = source.cgImage else { return page }
        let width = thumbnailPixels
        let height = Int((CGFloat(width) * CGFloat(source.pixelsHigh) / CGFloat(source.pixelsWide)).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return page }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return page }
        return NSImage(cgImage: small, size: page.size)
    }

    private static var tail: Task<Void, Never>?

    /// Waits for this caller's turn to draw: one page at a time, with a
    /// pause after each so the window can draw a frame between them.
    static func turn() async {
        let previous = tail
        let mine = Task { @MainActor in
            await previous?.value
            try? await Task.sleep(for: .milliseconds(6))
        }
        tail = mine
        await mine.value
    }

    /// Draws `text` as the editor would, on a page of the miniature's size.
    static func render(_ text: String, documentURL: URL?, dark: Bool, background: NSColor) -> NSImage {
        let size = NSSize(width: pageWidth, height: (pageWidth / aspect).rounded())
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let textView = PaperTextView()
        // As the PDF exporter's page: the editor's own window margins (a
        // wide minimum at the sides, a title band on top) are put back on
        // every resize, so a margin set on the view does not hold. A print
        // surface takes its side margin from here and has no band; the
        // top margin is the page's, below.
        textView.isPrintSurface = true
        textView.printHorizontalInset = margins.width
        textView.appearance = appearance
        let textSize = NSSize(width: size.width, height: size.height - margins.height)
        textView.frame = NSRect(origin: .zero, size: textSize)
        textView.documentURL = documentURL
        textView.string = text
        textView.syntaxStyler.apply(to: textView)
        textView.drawsBackground = true
        textView.backgroundColor = background
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
        }
        // The text view grows and shrinks to fit the text; the page is
        // held at its size, so a short note still fills it and a long one
        // is cut at its foot.
        textView.isVerticallyResizable = false
        textView.setFrameSize(textSize)
        let page = Page(frame: NSRect(origin: .zero, size: size), ground: background)
        page.appearance = appearance
        textView.setFrameOrigin(NSPoint(x: 0, y: margins.height))
        page.addSubview(textView)
        let bounds = NSRect(origin: .zero, size: size)
        let image = NSImage(size: size)
        appearance.performAsCurrentDrawingAppearance {
            // At 2x: without a window there is no backing scale to follow,
            // and a card on a Retina screen would blur at 1x.
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return }
            rep.size = size
            page.cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    /// The card's page: its ground, with the text view set into it below
    /// the top margin.
    private final class Page: NSView {
        let ground: NSColor
        init(frame: NSRect, ground: NSColor) {
            self.ground = ground
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            ground.setFill()
            dirtyRect.fill()
        }
    }

    private static func store(_ image: NSImage, for key: Key) {
        cache[key] = image
        order.append(key)
        while order.count > cacheLimit {
            cache[order.removeFirst()] = nil
        }
    }

    private static func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: Configuration.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                generation += 1
                cache.removeAll()
                order.removeAll()
            }
        }
    }
}
