import AppKit
import SwiftUI

/// Where each tile of a picture grid sits: as many square tiles to a row as
/// fit at 120 points or more, grown to fill the row up to 180, a hairline
/// gap between. Plain arithmetic, so the page can say where any tile is,
/// on screen or not, without a view for it.
struct MediaGridLayout: Equatable {
    static let smallest: CGFloat = 120
    static let largest: CGFloat = 180
    static let gap: CGFloat = 3

    let width: CGFloat
    let count: Int

    var columns: Int { max(1, Int((width + Self.gap) / (Self.smallest + Self.gap))) }

    var side: CGFloat {
        guard width > 0 else { return Self.smallest }
        return min((width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns), Self.largest)
    }

    var rows: Int { (count + columns - 1) / columns }

    var height: CGFloat {
        rows == 0 ? 0 : CGFloat(rows) * side + CGFloat(rows - 1) * Self.gap
    }

    func rect(_ index: Int) -> CGRect {
        let pitch = side + Self.gap
        return CGRect(x: CGFloat(index % columns) * pitch, y: CGFloat(index / columns) * pitch, width: side, height: side)
    }

    /// The tile under `point`; nil in a gap or past the last tile.
    func index(at point: CGPoint) -> Int? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        let pitch = side + Self.gap
        let column = Int(point.x / pitch), row = Int(point.y / pitch)
        guard column < columns else { return nil }
        let index = row * columns + column
        guard index < count, rect(index).contains(point) else { return nil }
        return index
    }

    /// The tiles of every row `rect` touches.
    func indices(in rect: CGRect) -> Range<Int> {
        guard count > 0, rect.maxY > 0, rect.minY < height else { return 0..<0 }
        let pitch = side + Self.gap
        let first = max(0, Int(rect.minY / pitch))
        let last = min(rows - 1, Int(rect.maxY / pitch))
        guard first <= last else { return 0..<0 }
        return (first * columns)..<min(count, (last + 1) * columns)
    }
}

/// A group's pictures, videos and sounds as one grid, drawn by AppKit the
/// way Photos draws its own: one view, with a layer for each tile near
/// what is in sight, handed on to the next tile as the page scrolls.
/// SwiftUI's lazy grid built and tore down a view for every tile, which
/// cost more than a frame at 120 Hz however little the tile held.
///
/// The grid only draws. Clicks and the pointer are read here in SwiftUI,
/// and the page's own drag, selection rectangle and menu find a tile by
/// the frames this reports, as they find a note card.
struct MediaGrid: View {
    let items: [FolderListing.Note]
    let selection: Set<URL>
    /// Tiles drawn faint: the ones Finder hides.
    let dimmed: Set<URL>
    let frames: CardFrames
    /// A click picks a tile, as in Finder; a double click opens it.
    let pick: (URL) -> Void
    let open: (URL) -> Void
    let hover: (URL, Bool) -> Void

    @State private var hovered: URL?
    /// The last click, to tell a double click on one tile.
    @State private var lastClick: (url: URL, at: Date)?
    /// Where the grid is, in the page's space.
    @State private var frame = CGRect.zero
    @Environment(\.libraryScrolling) private var scrolling

    private var layout: MediaGridLayout { MediaGridLayout(width: frame.width, count: items.count) }
    private var urls: [URL] { items.map(\.url) }

    var body: some View {
        MediaGridSurface(items: items, selection: selection, dimmed: dimmed, hovered: hovered)
            .allowsHitTesting(false)
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    // A tile is picked on the first click, with no wait to see
                    // whether a second is coming; a second soon after on the
                    // same tile opens it. Two quick clicks on two tiles are
                    // two picks, which the system's own double tap is not.
                    .onTapGesture(coordinateSpace: .local) { point in
                        guard let index = layout.index(at: point) else { return }
                        let url = items[index].url
                        let now = Date()
                        if let last = lastClick, last.url == url, now.timeIntervalSince(last.at) < NSEvent.doubleClickInterval {
                            lastClick = nil
                            open(url)
                        } else {
                            lastClick = (url, now)
                            pick(url)
                        }
                    }
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let point):
                            // A tile scrolled under the pointer does not grow.
                            guard !scrolling, !LibraryWheel.isEasing else { return }
                            pointer(at: layout.index(at: point).map { items[$0].url })
                        case .ended:
                            pointer(at: nil)
                        }
                    }
            }
            .onChange(of: scrolling) { if scrolling { pointer(at: nil) } }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(CardFrames.space)) } action: {
                frame = $0
                report()
            }
            .onChange(of: urls) { old, new in
                let kept = Set(new)
                for url in old where !kept.contains(url) { frames.local[url] = nil }
                if let hovered, !kept.contains(hovered) { self.hovered = nil }
                report()
            }
            .onDisappear { for url in urls { frames.local[url] = nil } }
    }

    private func pointer(at url: URL?) {
        guard url != hovered else { return }
        if let hovered { hover(hovered, false) }
        hovered = url
        if let url { hover(url, true) }
    }

    /// Every tile's frame in the page, seen or not.
    private func report() {
        guard frame.width > 0 else { return }
        let layout = layout
        for (index, item) in items.enumerated() {
            frames.local[item.url] = layout.rect(index).offsetBy(dx: frame.minX, dy: frame.minY)
        }
    }
}

private struct MediaGridSurface: NSViewRepresentable {
    let items: [FolderListing.Note]
    let selection: Set<URL>
    let dimmed: Set<URL>
    let hovered: URL?

    func makeNSView(context: Context) -> MediaGridView { MediaGridView() }

    func updateNSView(_ view: MediaGridView, context: Context) {
        view.show(items: items, selection: selection, dimmed: dimmed, hovered: hovered)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MediaGridView, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: MediaGridLayout(width: width, count: items.count).height)
    }
}

/// The grid's one view. It holds a layer for each tile in sight and for a
/// screen above and below, so a tile has its picture before it arrives.
@MainActor
final class MediaGridView: NSView {
    private var items: [FolderListing.Note] = []
    private var keys: [MediaPicture.Key] = []
    private var kinds: [LibraryKind] = []
    private var selection: Set<URL> = []
    private var dimmed: Set<URL> = []
    private var hovered: URL?
    private var tiles: [Int: MediaTileLayer] = [:]
    private var spare: [MediaTileLayer] = []
    /// Pictures asked for and not yet back.
    private var asked: Set<MediaPicture.Key> = []
    private var observed: NSObjectProtocol?
    private var look = MediaTileLook()

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    // The page reads clicks and the pointer; nothing lands here.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not built from a nib") }

    private var gridLayout: MediaGridLayout { MediaGridLayout(width: bounds.width, count: items.count) }

    func show(items: [FolderListing.Note], selection: Set<URL>, dimmed: Set<URL>, hovered: URL?) {
        let changed = items != self.items
        if changed {
            self.items = items
            keys = items.map { MediaPicture.key(for: $0.url, modified: $0.modified) }
            kinds = items.map { LibraryKind.of($0.url) ?? .image }
        }
        let restyled = selection != self.selection || dimmed != self.dimmed || hovered != self.hovered
        self.selection = selection
        self.dimmed = dimmed
        self.hovered = hovered
        if changed {
            reset()
        } else if restyled {
            for (index, tile) in tiles { style(tile, at: index, animated: true) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observed { NotificationCenter.default.removeObserver(observed) }
        observed = nil
        guard window != nil, let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        observed = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        look = MediaTileLook(appearance: effectiveAppearance, scale: window?.backingScaleFactor ?? 2)
        reset()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        look = MediaTileLook(appearance: effectiveAppearance, scale: window?.backingScaleFactor ?? 2)
        reset()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        look = MediaTileLook(appearance: effectiveAppearance, scale: window?.backingScaleFactor ?? 2)
        reset()
    }

    private var laidOutWidth: CGFloat = -1

    override func layout() {
        super.layout()
        // Only a new width moves the tiles; layout is also run for
        // changes that leave them where they are.
        guard bounds.width != laidOutWidth else { return refresh() }
        laidOutWidth = bounds.width
        reset()
    }

    /// Lays every tile out again: the items, the width or the look changed.
    private func reset() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for tile in tiles.values {
            tile.removeFromSuperlayer()
            spare.append(tile)
        }
        tiles.removeAll(keepingCapacity: true)
        CATransaction.commit()
        refresh()
    }

    /// Gives a layer to each tile near what is in sight and takes back the
    /// layers of those gone by. Run on every step of a scroll: it touches
    /// only the rows that came or went.
    private func refresh() {
        guard let layer, window != nil, bounds.width > 0 else { return }
        let seen = visibleRect
        guard !seen.isEmpty || !tiles.isEmpty else { return }
        let layout = gridLayout
        let wanted = seen.isEmpty ? 0..<0 : layout.indices(in: seen.insetBy(dx: 0, dy: -max(seen.height, 400)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, tile) in tiles where !wanted.contains(index) {
            tile.removeFromSuperlayer()
            spare.append(tile)
            tiles[index] = nil
        }
        for index in wanted where tiles[index] == nil {
            let tile = spare.popLast() ?? MediaTileLayer()
            tile.frame = backingAlignedRect(layout.rect(index), options: .alignAllEdgesNearest)
            fill(tile, at: index)
            style(tile, at: index, animated: false)
            layer.addSublayer(tile)
            tiles[index] = tile
        }
        CATransaction.commit()
    }

    /// The tile's picture: its own when it is in memory, the tiny one
    /// until then, with its own asked for.
    private func fill(_ tile: MediaTileLayer, at index: Int) {
        let key = keys[index], kind = kinds[index]
        tile.key = key
        let entry = MediaPicture.cached(key)
        tile.show(
            picture: entry?.image ?? MediaPicture.tiny(key), sharp: entry?.image != nil, kind: kind,
            name: items[index].url.lastPathComponent, duration: entry?.duration, look: look
        )
        guard entry == nil, !asked.contains(key) else { return }
        asked.insert(key)
        Task { [weak self] in
            let made = await MediaPicture.entry(for: key)
            guard let self else { return }
            self.asked.remove(key)
            guard let made, let (index, tile) = self.tiles.first(where: { $0.value.key == key }) else { return }
            tile.show(
                picture: made.image, sharp: true, kind: self.kinds[index],
                name: self.items[index].url.lastPathComponent, duration: made.duration, look: self.look, fading: true
            )
        }
    }

    /// The ring of a picked tile, the faintness of a hidden one, and the
    /// little growth of the one under the pointer.
    private func style(_ tile: MediaTileLayer, at index: Int, animated: Bool) {
        let url = items[index].url
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tile.ring.isHidden = !selection.contains(url)
        tile.opacity = dimmed.contains(url) ? 0.4 : 1
        CATransaction.commit()
        let grown = hovered == url
        guard grown != tile.grown else { return }
        tile.grown = grown
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.2))
        tile.zPosition = grown ? 1 : 0
        tile.transform = grown ? CATransform3DMakeScale(1.027, 1.027, 1) : CATransform3DIdentity
        CATransaction.commit()
    }
}

/// What every tile shares, worked out once for an appearance and a screen:
/// the gray of an empty tile, the ring, and the small drawn marks.
@MainActor
struct MediaTileLook {
    var scale: CGFloat = 2
    var ground = NSColor.gray.withAlphaComponent(0.08).cgColor
    var ring = NSColor.systemBlue.cgColor
    private var appearance = NSAppearance.currentDrawing()
    private static var marks: [String: CGImage] = [:]

    init() {}

    init(appearance: NSAppearance, scale: CGFloat) {
        self.appearance = appearance
        self.scale = scale
        appearance.performAsCurrentDrawingAppearance {
            ground = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            ring = NSColor.systemBlue.cgColor
        }
    }

    private var isDark: Bool { appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// A drawing as an image at the screen's scale, kept by `name`.
    private func mark(_ name: String, size: CGSize, draw: () -> Void) -> CGImage? {
        let id = "\(name)|\(scale)|\(isDark)"
        if let kept = Self.marks[id] { return kept }
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        appearance.performAsCurrentDrawingAppearance(draw)
        NSGraphicsContext.restoreGraphicsState()
        let image = context.makeImage()
        if Self.marks.count > 400 { Self.marks.removeAll() }
        Self.marks[id] = image
        return image
    }

    /// The dark pill at a video's or a sound's foot: a play mark and the
    /// length, as `VideoBadge` draws it.
    func badge(_ duration: String?) -> (image: CGImage, size: CGSize)? {
        let text = duration.map {
            NSAttributedString(string: $0, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white,
            ])
        }
        let textSize = text?.size() ?? .zero
        let triangle: CGFloat = 6.5, padX: CGFloat = duration == nil ? 6 : 7
        let size = CGSize(
            width: (padX * 2 + triangle + (text == nil ? 0 : 4 + textSize.width)).rounded(.up),
            height: max(textSize.height, triangle).rounded(.up) + 8
        )
        guard let image = mark("badge|\(duration ?? "")", size: size, draw: {
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: size.height / 2, yRadius: size.height / 2).fill()
            let path = NSBezierPath()
            let middle = size.height / 2
            path.move(to: NSPoint(x: padX, y: middle - triangle / 2))
            path.line(to: NSPoint(x: padX + triangle * 0.9, y: middle))
            path.line(to: NSPoint(x: padX, y: middle + triangle / 2))
            path.close()
            NSColor.white.setFill()
            path.fill()
            text?.draw(at: NSPoint(x: padX + triangle + 4, y: middle - textSize.height / 2))
        }) else { return nil }
        return (image, size)
    }

    /// A sound's face: its name at the head and a waveform in the middle.
    func face(name: String, side: CGFloat) -> CGImage? {
        let side = side.rounded()
        return mark("face|\(name)|\(side)", size: CGSize(width: side, height: side)) {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingMiddle
            NSAttributedString(string: name, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor.withAlphaComponent(0.55),
                .paragraphStyle: style,
            ]).draw(in: CGRect(x: 9, y: side - 8 - 15, width: side - 18, height: 15))
            let configuration = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
                .applying(.init(paletteColors: [NSColor.systemBlue]))
            if let wave = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                wave.draw(in: CGRect(
                    x: (side - wave.size.width) / 2, y: (side - wave.size.height) / 2,
                    width: wave.size.width, height: wave.size.height
                ))
            }
        }
    }
}

/// One tile: the picture filling a square, the pill and the ring over it.
final class MediaTileLayer: CALayer {
    var key: MediaPicture.Key?
    var grown = false
    let picture = CALayer()
    let face = CALayer()
    let badge = CALayer()
    let ring = CALayer()

    override init() {
        super.init()
        masksToBounds = true
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        ring.borderWidth = 2
        ring.isHidden = true
        for layer in [picture, face, badge, ring] { addSublayer(layer) }
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not built from a nib") }

    @MainActor
    func show(
        picture image: NSImage?, sharp: Bool, kind: LibraryKind, name: String, duration: String?,
        look: MediaTileLook, fading: Bool = false
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentsScale = look.scale
        backgroundColor = look.ground
        let box = CGRect(origin: .zero, size: bounds.size)
        for layer in [picture, face, ring] {
            layer.frame = box
            layer.contentsScale = look.scale
        }
        ring.borderColor = look.ring
        // A tiny picture is drawn soft; the tile's own, as it is.
        picture.magnificationFilter = sharp ? .linear : .trilinear
        picture.contents = image
        if fading {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.12
            picture.add(fade, forKey: "contents")
        }
        face.contents = kind == .audio ? look.face(name: name, side: box.width) : nil
        if kind == .video || kind == .audio, let mark = look.badge(duration) {
            badge.contents = mark.image
            badge.contentsScale = look.scale
            // The tile is flipped with its view: its foot is at the greater y.
            badge.frame = CGRect(x: 7, y: box.height - 7 - mark.size.height, width: mark.size.width, height: mark.size.height)
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }
        CATransaction.commit()
    }
}
