import AppKit
import AVFoundation
import CryptoKit
import os
import Quartz
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// What a card in the library shows: a note, a picture, a video or a sound. The
/// iPhone's listing, which the Mac shares, holds only notes; the Mac adds
/// a folder's pictures and videos to it here, as cards among the notes.
enum LibraryKind: String, CaseIterable, Sendable {
    case note, image, video, audio

    /// The kind of file at `url`, by its type as the system knows it; nil
    /// for anything the library does not show (PDFs, archives).
    /// Asked for every card on every draw, so each extension's answer is
    /// kept: the system's type lookup is too slow to repeat mid-scroll.
    static func of(_ url: URL) -> LibraryKind? {
        let ext = url.pathExtension.lowercased()
        if FolderListing.noteExtensions.contains(ext) { return .note }
        guard !ext.isEmpty else { return nil }
        if let known = known.withLock({ $0[ext] }) { return known }
        let kind = looked(up: ext)
        known.withLock { $0[ext] = kind }
        return kind
    }

    private static func looked(up ext: String) -> LibraryKind? {
        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }

    /// Each extension's kind once looked up; nil kinds are kept too.
    private static let known = OSAllocatedUnfairLock<[String: LibraryKind?]>(initialState: [:])

    static func isMedia(_ url: URL) -> Bool {
        switch of(url) {
        case .image, .video, .audio: true
        default: false
        }
    }
}

extension FolderListing {
    /// The listing with the folder's pictures and videos among its notes,
    /// newest first like them, and every folder's count taking its own in.
    /// `hidden` gains the media Finder hides, when those are shown.
    static func addingMedia(
        to listing: FolderListing, hidden: Set<URL>, in folder: URL, includingHidden: Bool
    ) -> (listing: FolderListing, hidden: Set<URL>) {
        var listing = listing
        var hidden = hidden
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .isHiddenKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: includingHidden ? [] : [.skipsHiddenFiles]
        )) ?? []
        for entry in entries where LibraryKind.isMedia(entry) {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory != true else { continue }
            listing.notes.append(Note(
                url: entry, title: entry.lastPathComponent,
                modified: values?.contentModificationDate ?? .distantPast
            ))
            if entry.lastPathComponent.hasPrefix(".") || values?.isHidden == true { hidden.insert(entry) }
        }
        listing.notes.sort { $0.modified > $1.modified }
        listing.folders = listing.folders.map { item in
            Folder(url: item.url, name: item.name, itemCount: item.itemCount + mediaCount(in: item.url, includingHidden: includingHidden))
        }
        return (listing, hidden)
    }

    private static func mediaCount(in folder: URL, includingHidden: Bool) -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [], options: includingHidden ? [] : [.skipsHiddenFiles]
        )) ?? []
        return entries.filter(LibraryKind.isMedia).count
    }
}

// MARK: Pictures

/// The pictures on media cards. Photos never shows an empty tile because
/// it never makes a picture while scrolling: it draws from thumbnails made
/// beforehand. So here. Each file has two, made once from the system's own
/// thumbnail and kept on disk while the file is unchanged: a tile-size
/// picture, and a tiny one of a few dozen pixels. A folder's tiny pictures
/// are all held in memory, so every tile draws at once, soft, at any
/// scroll speed; the tile-size pictures are held for the stretch of the
/// folder in view and read back from disk, a millisecond or two each, as
/// the page scrolls. Only a folder never seen before has pictures to make.
@MainActor
enum MediaPicture {
    /// How a picture sits in its card: filling it, cropped at the edges,
    /// or whole inside it with the card's ground around it.
    static var fills = true

    /// The tile-size pictures kept in memory, about half a megabyte each.
    static let cacheLimit = 500
    /// How many of a folder's first pictures are read into memory as soon
    /// as the folder is.
    static let warmed = 150

    struct Key: Hashable, Sendable {
        let url: URL
        let modified: Date
        let fills: Bool
    }

    struct Entry {
        /// Nil for a sound, whose tile is drawn and not pictured.
        let image: NSImage?
        /// A video's or a sound's length, as the card shows it.
        let duration: String?
    }

    private static var cache: [Key: Entry] = [:]
    private static var order: [Key] = []
    /// Every tiny picture read so far; a few kilobytes each, never let go.
    private static var tinies: [Key: NSImage] = [:]
    /// Pictures being made now, so a tile and a prefetch share one request.
    private static var making: [Key: Task<Entry?, Never>] = [:]
    /// Files the system had no thumbnail for, and when: a file still being
    /// copied in has none yet, so one is asked again after a while, not
    /// on every listing.
    private static var failures: [Key: Date] = [:]
    private static func failed(_ key: Key) -> Bool {
        failures[key].map { Date().timeIntervalSince($0) < 2 } ?? false
    }
    private static var prefetching: Task<Void, Never>?

    static func key(for url: URL, modified: Date, fills: Bool = MediaPicture.fills) -> Key {
        Key(url: url.standardizedFileURL, modified: modified, fills: fills)
    }

    static func cached(_ key: Key) -> Entry? { cache[key] }

    /// The tiny picture, drawn under a tile until its own is read.
    static func tiny(_ key: Key) -> NSImage? { tinies[key] }

    /// The card's picture: from memory, else from disk, else made now. Nil
    /// when the system has no thumbnail for the file.
    static func entry(for key: Key) async -> Entry? {
        if let cached = cache[key] { return cached }
        if failed(key) { return nil }
        if let pending = making[key] { return await pending.value }
        let task = Task { await make(key, keep: true) }
        making[key] = task
        let entry = await task.value
        making[key] = nil
        return entry
    }

    /// As soon as a folder is read: its tiny pictures into memory in one
    /// go, its first tile-size ones after them, and any picture not yet on
    /// disk made, four at a time from the top, so the next scroll and the
    /// next visit draw from disk.
    static func prefetch(_ items: [FolderListing.Note]) {
        let keys = items.filter { LibraryKind.isMedia($0.url) }.map { key(for: $0.url, modified: $0.modified) }
        let wanted = keys.enumerated().filter { index, key in
            !failed(key) && (tinies[key] == nil || (index < warmed && cache[key] == nil))
        }
        guard !wanted.isEmpty else { return }
        prefetching?.cancel()
        prefetching = Task {
            let missing = wanted.map(\.element).filter { tinies[$0] == nil && LibraryKind.of($0.url) != .audio }
            let found = await Task.detached(priority: .userInitiated) {
                Found(pairs: missing.compactMap { key in MediaTileStore.tiny(key).map { (key, $0) } })
            }.value
            for (key, image) in found.pairs where tinies[key] == nil { tinies[key] = picture(image) }
            let queue = Queue(work: wanted.map { ($0.offset, $0.element) })
            let workers = (0..<4).map { _ in Task { await drain(queue) } }
            await withTaskCancellationHandler {
                for worker in workers { await worker.value }
            } onCancel: {
                for worker in workers { worker.cancel() }
            }
        }
    }

    /// What a prefetch has left to do, shared by its four workers.
    private final class Queue {
        let work: [(index: Int, key: Key)]
        var next = 0
        init(work: [(index: Int, key: Key)]) { self.work = work }
    }

    private static func drain(_ queue: Queue) async {
        while queue.next < queue.work.count, !Task.isCancelled {
            let (index, key) = queue.work[queue.next]
            queue.next += 1
            if index < warmed {
                _ = await entry(for: key)
            } else if tinies[key] == nil, cache[key] == nil, making[key] == nil {
                // Past what memory holds: made and written, not kept.
                _ = await make(key, keep: false)
            }
        }
    }

    private struct Found: @unchecked Sendable { let pairs: [(Key, CGImage)] }
    private struct Made: @unchecked Sendable { let image: CGImage?; let tiny: CGImage? }

    private static func picture(_ image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }

    private static func make(_ key: Key, keep: Bool) async -> Entry? {
        // A sound has no picture: only its length is read.
        if LibraryKind.of(key.url) == .audio {
            var duration = await Task.detached { MediaTileStore.length(key) }.value
            if duration == nil {
                duration = await length(of: key.url)
                let found = duration
                Task.detached(priority: .utility) { MediaTileStore.write(key, picture: nil, length: found) }
            }
            let entry = Entry(image: nil, duration: duration)
            store(entry, for: key)
            return entry
        }
        // Kept on disk from before: read, a millisecond or two.
        let read = await Task.detached(priority: .userInitiated) { () -> (Made, String?)? in
            guard let image = MediaTileStore.picture(key) else { return nil }
            return (Made(image: image, tiny: MediaTileStore.tiny(key)), MediaTileStore.length(key))
        }.value
        if let (made, duration) = read, let image = made.image {
            if tinies[key] == nil, let tiny = made.tiny { tinies[key] = picture(tiny) }
            let entry = Entry(image: picture(image), duration: duration)
            if keep { store(entry, for: key) }
            return entry
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: key.url, size: CGSize(width: 600, height: 600), scale: 2, representationTypes: .thumbnail
        )
        guard let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            failures[key] = Date()
            return nil
        }
        let duration = LibraryKind.of(key.url) == .video ? await length(of: key.url) : nil
        // Off the main thread: scaling a full-size picture, and bringing a
        // wide-gamut one to sRGB, takes tens of milliseconds each, and on
        // the main thread a folder of them stalled every scroll.
        let source = thumbnail.cgImage
        let fills = key.fills
        let made = await Task.detached(priority: .userInitiated) { () -> Made in
            let small = card(source, fills: fills)
            let tiny = MediaTileStore.write(key, picture: small, length: duration)
            return Made(image: small, tiny: tiny)
        }.value
        if let tiny = made.tiny { tinies[key] = picture(tiny) }
        let entry = Entry(image: made.image.map(picture), duration: duration)
        if keep { store(entry, for: key) }
        return entry
    }

    /// The thumbnail at the tile's size: cropped to it, or scaled to fit
    /// inside it.
    nonisolated static func card(_ source: CGImage, fills: Bool) -> CGImage {
        let width = CGFloat(source.width), height = CGFloat(source.height)
        // A tile is at most 180 pt wide: 360 pixels on a Retina screen.
        let box = CGSize(width: 360, height: 360)
        let scale = fills ? max(box.width / width, box.height / height) : min(box.width / width, box.height / height, 1)
        let drawn = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        let canvas = fills ? box : drawn
        guard let context = CGContext(
            data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return source }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(
            x: (canvas.width - drawn.width) / 2, y: (canvas.height - drawn.height) / 2,
            width: drawn.width, height: drawn.height
        ))
        return context.makeImage() ?? source
    }

    /// `1:05`, or `1:02:05` past the hour.
    static func format(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    private static func length(of url: URL) async -> String? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric else { return nil }
        let seconds = duration.seconds
        return seconds > 0 ? format(seconds: seconds) : nil
    }

    private static func store(_ entry: Entry, for key: Key) {
        cache[key] = entry
        order.append(key)
        while order.count > cacheLimit { cache[order.removeFirst()] = nil }
    }
}

/// The pictures kept on disk, in the caches folder, where the system may
/// clear them: for each file as it was last changed, a tile-size JPEG, a
/// tiny one, and a video's or a sound's length.
enum MediaTileStore {
    static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Paper", isDirectory: true)
            .appendingPathComponent("LibraryTiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The tiny picture's longer edge, in pixels.
    static let tinyEdge: CGFloat = 40

    private static func file(_ key: MediaPicture.Key, _ ext: String) -> URL {
        let text = "\(key.url.path)|\(key.modified.timeIntervalSinceReferenceDate)|\(key.fills)"
        let name = SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension(ext)
    }

    static func picture(_ key: MediaPicture.Key) -> CGImage? { decoded(file(key, "jpg")) }
    static func tiny(_ key: MediaPicture.Key) -> CGImage? { decoded(file(key, "tiny.jpg")) }

    static func length(_ key: MediaPicture.Key) -> String? {
        try? String(contentsOf: file(key, "len"), encoding: .utf8)
    }

    /// The image decoded here and now, not when it is first drawn: that
    /// would be on the main thread, mid-scroll.
    private static func decoded(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Writes the tile's picture, a tiny one made from it, and the length;
    /// returns the tiny one.
    @discardableResult
    static func write(_ key: MediaPicture.Key, picture: CGImage?, length: String?) -> CGImage? {
        if let length { try? length.write(to: file(key, "len"), atomically: true, encoding: .utf8) }
        guard let picture else { return nil }
        save(picture, to: file(key, "jpg"), quality: 0.82)
        let scale = tinyEdge / CGFloat(max(picture.width, picture.height))
        let size = CGSize(width: max(1, (CGFloat(picture.width) * scale).rounded()), height: max(1, (CGFloat(picture.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(picture, in: CGRect(origin: .zero, size: size))
        guard let tiny = context.makeImage() else { return nil }
        save(tiny, to: file(key, "tiny.jpg"), quality: 0.7)
        return tiny
    }

    private static func save(_ image: CGImage, to url: URL, quality: Double) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}

// MARK: Card

/// A picture's or a video's tile, as the Photos grid draws one: a square
/// with square corners, the picture filling it, and on a video its length.
struct MediaCard: View {
    let item: FolderListing.Note
    let kind: LibraryKind
    var selected = false
    var picture: Image?
    /// The tiny picture, drawn soft until the tile's own is read.
    var tiny: Image?
    var duration: String?
    var fills = true

    /// The tile before its picture lands: a quiet gray, as a picture still
    /// loading, not a white card.
    static let ground = Color.primary.opacity(0.08)

    // Kept to few layers: a row of tiles is built in one frame of a
    // scroll, and each layer here is paid for nine times over.
    var body: some View {
        Self.ground
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if picture == nil, let tiny {
                    if fills {
                        tiny.resizable().interpolation(.medium).scaledToFill()
                    } else {
                        tiny.resizable().interpolation(.medium).scaledToFit().padding(10)
                    }
                }
            }
            .overlay {
                if let picture {
                    if fills {
                        picture.resizable().scaledToFill()
                    } else {
                        picture.resizable().scaledToFit().padding(10)
                    }
                }
            }
            .animation(.easeOut(duration: 0.18), value: picture == nil)
            .clipped()
            // A sound has no picture, so its tile says what it is: its
            // name at the head, as nothing else tells two apart, and a
            // waveform in the middle.
            .overlay {
                if kind == .audio {
                    Image(systemName: "waveform")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.42))
                }
            }
            .overlay(alignment: .topLeading) {
                if kind == .audio {
                    Text(item.url.lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 9)
                        .padding(.top, 8)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if kind == .video || kind == .audio { VideoBadge(duration: duration).padding(7) }
            }
            .overlay {
                if selected {
                    Rectangle().strokeBorder(LibrarySelectionRing.color, lineWidth: LibrarySelectionRing.width)
                }
            }
            .contentShape(Rectangle())
            .accessibilityLabel(item.url.lastPathComponent)
    }
}

/// A small dark capsule at a video card's foot: a play mark and the length.
struct VideoBadge: View {
    let duration: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "play.fill").font(.system(size: 7, weight: .bold))
            if let duration {
                Text(duration).font(.system(size: 10, weight: .semibold)).monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, duration == nil ? 6 : 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.55)))
    }
}

/// The card for a picture or video in the grid, its picture made when the
/// card first shows.
struct LibraryMediaTile: View {
    let item: FolderListing.Note
    let kind: LibraryKind
    let selected: Bool
    var fills = MediaPicture.fills
    @State private var entry: MediaPicture.Entry?

    private var key: MediaPicture.Key { MediaPicture.key(for: item.url, modified: item.modified, fills: fills) }

    var body: some View {
let shown = entry ?? MediaPicture.cached(key)
        MediaCard(
            item: item, kind: kind, selected: selected,
            picture: shown?.image.map { Image(nsImage: $0) },
            tiny: shown?.image == nil ? MediaPicture.tiny(key).map { Image(nsImage: $0) } : nil,
            duration: shown?.duration, fills: fills
        )
        .task(id: key) {
            if let cached = MediaPicture.cached(key) {
                entry = cached
                return
            }
            // A file just dropped in may not be whole yet: asked again,
            // a few times, before the tile is left gray.
            for wait in [0.0, 1, 3, 6] {
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if Task.isCancelled { return }
                if let made = await MediaPicture.entry(for: key) {
                    entry = made
                    return
                }
            }
        }
    }
}

// MARK: Quick Look

/// A media card opens in the system's Quick Look panel, as the editor's
/// images do: a picture whole, a video playing, ← → across the folder's
/// pictures and videos in the order the page shows them.
@MainActor
final class LibraryPreview: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = LibraryPreview()

    private(set) var items: [URL] = []
    /// Where a card is on screen now, for the panel to grow out of and
    /// shrink back into; zero when the card is out of sight. Asked each
    /// time, since the page may have scrolled, or the panel stepped to
    /// another picture, since it opened.
    private var frame: (URL) -> NSRect = { _ in .zero }

    var isShowing: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    /// Shows `url`, stepping through `items`. `frame` answers in screen space.
    func show(_ url: URL, among items: [URL], frame: @escaping (URL) -> NSRect) {
        self.items = items.isEmpty ? [url] : items
        self.frame = frame
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = self.items.firstIndex(of: url) ?? 0
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard isShowing else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    /// The panel hands control to whoever answers for the key window; a
    /// library window's delegate answers with this.
    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func end(_ panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        items.indices.contains(index) ? items[index] as NSURL : nil
    }

    /// Where the panel grows from and shrinks back to. A tile shows the
    /// middle of its picture, cropped to a square, and the panel animates
    /// the whole picture: so the frame given is the whole picture's, at
    /// the size that fills the tile and centered on it. The picture then
    /// lands exactly over the part of itself the tile shows.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item.previewItemURL else { return .zero }
        let tile = frame(url)
        guard tile.width > 0, let size = transition(for: url)?.size, size.width > 0, size.height > 0 else { return tile }
        let scale = max(tile.width / size.width, tile.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return NSRect(x: tile.midX - width / 2, y: tile.midY - height / 2, width: width, height: height)
    }

    /// The picture the panel animates: a small one of the whole picture.
    /// Left to itself the panel animates the file's full picture, and a
    /// large one stutters.
    func previewPanel(
        _ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!
    ) -> Any! {
        item.previewItemURL.flatMap(transition)
    }

    /// The last few transition pictures made, asked for on the way in and
    /// again on the way out.
    private var transitions: [(url: URL, image: NSImage)] = []

    /// A small picture of the whole of an image file, uncropped; nil for a
    /// video or a sound, which the panel animates on its own.
    private func transition(for url: URL) -> NSImage? {
        if let kept = transitions.first(where: { $0.url == url }) { return kept.image }
        guard LibraryKind.of(url) == .image, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
        transitions.append((url, image))
        if transitions.count > 6 { transitions.removeFirst() }
        return image
    }
}

/// A frame in a window's content, from its top left as SwiftUI's global
/// space has it, on screen.
@MainActor
func screenRect(_ rect: CGRect, in window: NSWindow?) -> NSRect {
    guard let window, let content = window.contentView else { return .zero }
    let flipped = NSRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    return window.convertToScreen(content.convert(flipped, to: nil))
}

// MARK: Glyphs

/// A picture: a frame with a sun and a hill.
struct PictureGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: rect.minX + 3.5 * s, y: rect.minY + 5 * s, width: 17 * s, height: 14 * s),
            cornerSize: CGSize(width: 2.5 * s, height: 2.5 * s), style: .continuous
        )
        path.addEllipse(in: CGRect(x: rect.minX + 7 * s, y: rect.minY + 8 * s, width: 3 * s, height: 3 * s))
        path.move(to: p(3.8, 17))
        path.addLine(to: p(9, 12.5))
        path.addLine(to: p(13, 15.5))
        path.addLine(to: p(15.5, 13.5))
        path.addLine(to: p(20.2, 17.5))
        return path
    }
}

/// A sound: five bars of a waveform.
struct WaveGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var path = Path()
        for (x, half) in [(4.5, 2.0), (8.25, 5.0), (12.0, 7.5), (15.75, 4.0), (19.5, 2.0)] as [(CGFloat, CGFloat)] {
            path.move(to: CGPoint(x: rect.minX + x * s, y: rect.minY + (12 - half) * s))
            path.addLine(to: CGPoint(x: rect.minX + x * s, y: rect.minY + (12 + half) * s))
        }
        return path
    }
}

/// A video: a frame with a play mark in it.
struct FilmGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: rect.minX + 3.5 * s, y: rect.minY + 5 * s, width: 17 * s, height: 14 * s),
            cornerSize: CGSize(width: 2.5 * s, height: 2.5 * s), style: .continuous
        )
        path.move(to: p(10.5, 9.2))
        path.addLine(to: p(15, 12))
        path.addLine(to: p(10.5, 14.8))
        path.closeSubpath()
        return path
    }
}

/// A note: a page with a folded corner and two lines.
struct PageGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(14, 3.5))
        path.addLine(to: p(8, 3.5))
        path.addQuadCurve(to: p(5.5, 6), control: p(5.5, 3.5))
        path.addLine(to: p(5.5, 18))
        path.addQuadCurve(to: p(8, 20.5), control: p(5.5, 20.5))
        path.addLine(to: p(16, 20.5))
        path.addQuadCurve(to: p(18.5, 18), control: p(18.5, 20.5))
        path.addLine(to: p(18.5, 8))
        path.closeSubpath()
        path.move(to: p(14, 3.5))
        path.addLine(to: p(14, 8))
        path.addLine(to: p(18.5, 8))
        path.move(to: p(9, 12.5))
        path.addLine(to: p(15, 12.5))
        path.move(to: p(9, 16))
        path.addLine(to: p(13, 16))
        return path
    }
}

/// Kind: a tall card for a note beside a square and a round for the
/// other kinds.
struct KindGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: rect.minX + 4 * s, y: rect.minY + 4.5 * s, width: 7 * s, height: 15 * s),
            cornerSize: CGSize(width: 2 * s, height: 2 * s), style: .continuous
        )
        path.addRoundedRect(
            in: CGRect(x: rect.minX + 13.5 * s, y: rect.minY + 4.5 * s, width: 6.5 * s, height: 6.5 * s),
            cornerSize: CGSize(width: 1.8 * s, height: 1.8 * s), style: .continuous
        )
        path.addEllipse(in: CGRect(x: rect.minX + 13.5 * s, y: rect.minY + 13 * s, width: 6.5 * s, height: 6.5 * s))
        return path
    }
}
