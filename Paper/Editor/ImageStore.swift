#if os(macOS)
import AppKit
#else
import UIKit
#endif
import ImageIO
import OSLog

/// Loads the images a document embeds and remembers them for the session.
/// Only local files load: a remote destination makes a network request the
/// moment a document opens, which Paper does not do on the author's behalf,
/// so it stands as its alt text like a missing file.
///
/// Two caches. Pixel dimensions are read from the file header on the main
/// actor — cheap, and needed at style time so the band under an image line
/// is reserved before any bitmap exists. Bitmaps decode on demand: a text
/// view tells the store which files its viewport shows and which lie one
/// viewport away, and the store decodes those, visible first, one at a
/// time. Drawing never asks for a decode — AppKit paints well beyond the
/// viewport for responsive scrolling, and a draw-driven decode would pull
/// in every image it prepares. The decoded bitmap is downsampled to what
/// the measure can show, so a 6000-pixel screenshot does not become a
/// 6000-pixel texture.
@MainActor
final class ImageStore {
    static let shared = ImageStore()

    /// Posted on the main actor, with the file URL as `object`, when a
    /// bitmap has decoded; a view showing it redraws.
    static let didLoadNotification = Notification.Name("org.humanitas.paper.ImageStore.didLoad")

    struct Entry {
        let image: NSImage
        /// The natural size in points, taken as the pixel size the way a
        /// browser shows it, before any fit to the measure.
        let naturalSize: NSSize
        /// The decoded bitmap's bytes, what the cache budget counts. Taken
        /// from the CGImage: an NSImage rep reports pixels at the display
        /// scale, which over-counts a Retina bitmap fourfold.
        let bytes: Int
    }

    struct Dimensions {
        let naturalSize: NSSize
    }

    /// What the decoder hands back across the actor boundary.
    struct Decoded: Sendable {
        let cgImage: CGImage
        let naturalSize: NSSize
    }

    private struct Cached {
        let entry: Entry?
        let modified: Date?
        let bytes: Int
    }

    private struct CachedDimensions {
        let dimensions: Dimensions?
        let modified: Date?
    }

    /// What one text view wants: the files in its viewport, then the
    /// files within a viewport of it, each in document order.
    private struct Demand {
        var visible: [URL]
        var prefetch: [URL]
    }

    private var cache: [URL: Cached] = [:]
    private var dimensionCache: [URL: CachedDimensions] = [:]
    /// Least recently used first; eviction order for the byte budget.
    private var recency: [URL] = []
    private var totalBytes = 0

    /// Demand per text view, in the order the views first registered, so
    /// the queue is stable across updates.
    private var demands: [ObjectIdentifier: Demand] = [:]
    private var owners: [ObjectIdentifier] = []
    /// The union of every owner's visible list: never evicted.
    private var pinned: Set<URL> = []
    /// The files waiting to decode, highest priority first, none of them
    /// resident or in flight.
    private var queue: [URL] = []
    /// The one decode in flight. Nothing else starts until its result has
    /// been admitted or discarded, so at most one bitmap ever sits outside
    /// the cache.
    private var active: URL?
    /// Bumped by `forget(_:)`; a decode that started under an older
    /// generation is stale and its result is dropped.
    private var generations: [URL: Int] = [:]
    /// Demanded files that landed and evicted themselves: the budget is
    /// full of pinned or newer images. They wait, rather than decode and
    /// evict in a loop, until something is dropped or they become visible.
    private var unfit: Set<URL> = []

    /// The longest edge the decoded bitmap keeps, in pixels: twice the
    /// widest measure Settings allows, for Retina.
    nonisolated static let maximumPixelEdge: CGFloat = 2 * 1200

    /// The decoded bitmaps the cache may hold at once; the least recently
    /// used unpinned ones are dropped past it and decode again when next
    /// demanded. Visible images are pinned, so the cache exceeds the
    /// budget only when the viewport alone does. A variable so tests can
    /// shrink it.
    var byteBudget = 256 << 20
    /// Bounds the entry count too: missing files cache a nil at zero bytes,
    /// and a document can name any number of those.
    var entryLimit = 512

    /// The function that decodes a file off the main actor. A variable so
    /// tests can hold a decode open and observe the store mid-flight.
    var decode: @Sendable (URL) -> Decoded? = ImageStore.load

    // MARK: - Counters (tests and profiling)

    /// `log stream --predicate 'subsystem == "org.humanitas.paper"' --level debug`
    /// shows every decode start, admission, discard, and eviction.
    private static let log = Logger(subsystem: "org.humanitas.paper", category: "images")

    /// Every URL a decode started for, in order.
    private(set) var decodeStarts: [URL] = []
    private(set) var admissions = 0
    private(set) var discards = 0
    private(set) var evictions = 0

    // MARK: - Dimensions

    /// The pixel dimensions of the image at `url` from its header, or nil
    /// when it is remote, missing, or unreadable. Synchronous and cheap: no
    /// pixel is decoded. A file edited since it was cached is read again.
    func dimensions(for url: URL) -> Dimensions? {
        guard url.isFileURL else { return nil }
        let modified = Self.modificationDate(of: url)
        if let cached = dimensionCache[url], cached.modified == modified {
            return cached.dimensions
        }
        let dimensions = Self.readDimensions(url).map { Dimensions(naturalSize: $0) }
        if dimensionCache.count >= entryLimit * 4 { dimensionCache.removeAll() }
        dimensionCache[url] = CachedDimensions(dimensions: dimensions, modified: modified)
        return dimensions
    }

    // MARK: - Bitmaps

    /// The decoded bitmap at `url` if it is resident and current, else nil.
    /// Never starts a decode and never touches recency: drawing calls this,
    /// and AppKit draws far beyond the viewport. Demand drives both.
    func residentImage(for url: URL) -> Entry? {
        guard url.isFileURL, let cached = cache[url] else { return nil }
        guard cached.modified == Self.modificationDate(of: url) else { return nil }
        return cached.entry
    }

    /// The decoded bitmap at `url`, decoding on the caller's thread when it
    /// is not resident. For callers that must have the bitmap now — the
    /// tests and render probes; the drawing path uses `residentImage(for:)`.
    func entry(for url: URL) -> Entry? {
        guard url.isFileURL else { return nil }
        let modified = Self.modificationDate(of: url)
        if let cached = cache[url], cached.modified == modified {
            touch(url)
            return cached.entry
        }
        let entry = decode(url).map(Self.entry)
        store(entry, for: url, modified: modified)
        return entry
    }

    /// Drops everything known about `url`: a decode in flight for it is
    /// stale, and it is read again the next time it is demanded.
    func forget(_ url: URL) {
        dimensionCache[url] = nil
        generations[url, default: 0] += 1
        drop(url)
        rebuildQueue()
        pump()
    }

    /// Whether `url`'s bitmap is decoded and resident (tests).
    func isCached(_ url: URL) -> Bool {
        cache[url] != nil
    }

    /// The bytes the resident bitmaps account for (tests).
    var residentBytes: Int { totalBytes }

    /// Whether `url` is the decode in flight (tests).
    func isDecoding(_ url: URL) -> Bool {
        active == url
    }

    /// Whether `url` waits to decode (tests).
    func isQueued(_ url: URL) -> Bool {
        queue.contains(url)
    }

    // MARK: - Demand

    /// Sets what the text view `owner` wants decoded: `visible` are the
    /// files in its viewport, `prefetch` those within a viewport of it,
    /// each in document order. Visible files are pinned against eviction
    /// and decode before any prefetch; files no longer named by any owner
    /// leave the queue. The decode in flight, if it loses all demand, is
    /// discarded when it finishes rather than admitted.
    func updateDemand(for owner: ObjectIdentifier, visible: [URL], prefetch: [URL]) {
        let visible = visible.filter(\.isFileURL)
        let prefetch = prefetch.filter { $0.isFileURL && !visible.contains($0) }
        if demands[owner] == nil { owners.append(owner) }
        demands[owner] = Demand(visible: visible, prefetch: prefetch)
        // Demand is what makes an image recent: prefetch first, then
        // visible, so the viewport's own images are the last to go.
        for url in prefetch where cache[url] != nil { touch(url) }
        for url in visible where cache[url] != nil { touch(url) }
        demandDidChange()
    }

    /// Forgets `owner`'s demand: its document closed.
    func removeDemand(for owner: ObjectIdentifier) {
        guard demands.removeValue(forKey: owner) != nil else { return }
        owners.removeAll { $0 == owner }
        demandDidChange()
    }

    private func demandDidChange() {
        pinned = Set(owners.flatMap { demands[$0]?.visible ?? [] })
        rebuildQueue()
        evictIfNeeded()
        pump()
    }

    /// The queue is every demanded file not resident and not in flight:
    /// all owners' visible files first, then their prefetch files, each
    /// once, in owner then document order.
    private func rebuildQueue() {
        var seen: Set<URL> = []
        var next: [URL] = []
        let ordered = owners.flatMap { demands[$0]?.visible ?? [] } + owners.flatMap { demands[$0]?.prefetch ?? [] }
        for url in ordered where seen.insert(url).inserted {
            guard url != active, !isResident(url) else { continue }
            guard !unfit.contains(url) || pinned.contains(url) else { continue }
            next.append(url)
        }
        queue = next
    }

    private func isDemanded(_ url: URL) -> Bool {
        demands.values.contains { $0.visible.contains(url) || $0.prefetch.contains(url) }
    }

    private func isResident(_ url: URL) -> Bool {
        guard let cached = cache[url] else { return false }
        return cached.modified == Self.modificationDate(of: url)
    }

    // MARK: - Decoding

    /// Starts the next decode when none is in flight. One at a time, and
    /// the next does not start until the previous result has been admitted
    /// or discarded on the main actor, so the transient memory of a
    /// forty-image document is one bitmap, not forty.
    private func pump() {
        guard active == nil, !queue.isEmpty else { return }
        let url = queue.removeFirst()
        let modified = Self.modificationDate(of: url)
        let generation = generations[url, default: 0]
        active = url
        decodeStarts.append(url)
        Self.log.debug("decode start \(url.lastPathComponent, privacy: .public) queued=\(self.queue.count)")
        let decode = decode
        let job = Task.detached(priority: .userInitiated) { decode(url) }
        Task { @MainActor in
            let decoded = await job.value
            self.admit(decoded, for: url, modified: modified, generation: generation)
        }
    }

    private func admit(_ decoded: Decoded?, for url: URL, modified: Date?, generation: Int) {
        active = nil
        let current = generations[url, default: 0] == generation && modified == Self.modificationDate(of: url)
        if current, isDemanded(url) {
            admissions += 1
            Self.log.debug("decode admit \(url.lastPathComponent, privacy: .public)")
            store(decoded.map(Self.entry), for: url, modified: modified)
            if isResident(url) {
                NotificationCenter.default.post(name: Self.didLoadNotification, object: url)
            } else {
                unfit.insert(url)
                Self.log.debug("decode unfit \(url.lastPathComponent, privacy: .public)")
            }
        } else {
            // Stale or unwanted: drop it. A stale file still demanded goes
            // back in the queue, since it is not resident.
            discards += 1
            Self.log.debug("decode discard \(url.lastPathComponent, privacy: .public)")
        }
        rebuildQueue()
        pump()
    }

    // MARK: - Cache

    private func store(_ entry: Entry?, for url: URL, modified: Date?) {
        drop(url)
        let bytes = entry?.bytes ?? 0
        cache[url] = Cached(entry: entry, modified: modified, bytes: bytes)
        recency.append(url)
        totalBytes += bytes
        evictIfNeeded()
    }

    /// Removes `url`'s bitmap, if resident. Room freed is room for a
    /// file that did not fit before.
    private func drop(_ url: URL) {
        guard let cached = cache.removeValue(forKey: url) else { return }
        totalBytes -= cached.bytes
        recency.removeAll { $0 == url }
        if cached.bytes > 0 { unfit.removeAll() }
    }

    private func touch(_ url: URL) {
        guard recency.last != url else { return }
        recency.removeAll { $0 == url }
        recency.append(url)
    }

    /// Drops least recently used entries past the budgets, skipping the
    /// pinned (visible) ones: a visible image evicted would flash back to
    /// its placeholder. When the visible images alone exceed the budget the
    /// cache stays over it until they scroll away.
    private func evictIfNeeded() {
        while totalBytes > byteBudget || cache.count > entryLimit {
            guard let victim = recency.first(where: { !pinned.contains($0) }) else { return }
            drop(victim)
            evictions += 1
            Self.log.debug("evict \(victim.lastPathComponent, privacy: .public) resident=\(self.totalBytes >> 20)MB")
        }
    }

    /// UIKit images take their size from the bitmap; every draw gives the
    /// rect, so the natural size is carried beside it in the entry.
    private static func image(_ decoded: Decoded) -> NSImage {
        #if os(macOS)
        NSImage(cgImage: decoded.cgImage, size: decoded.naturalSize)
        #else
        UIImage(cgImage: decoded.cgImage)
        #endif
    }

    private static func entry(_ decoded: Decoded) -> Entry {
        Entry(
            image: image(decoded),
            naturalSize: decoded.naturalSize,
            bytes: decoded.cgImage.bytesPerRow * decoded.cgImage.height
        )
    }

    // MARK: - File access

    nonisolated private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// The upright pixel size from the header alone. EXIF orientations 5–8
    /// rotate a quarter turn, so their width and height swap.
    nonisolated private static func readDimensions(_ url: URL) -> NSSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return orientation >= 5 ? NSSize(width: height, height: width) : NSSize(width: width, height: height)
    }

    /// Decodes the file at `url`, downsampled to `maximumPixelEdge`. Runs
    /// off the main actor; the store's default `decode`.
    nonisolated static func load(_ url: URL) -> Decoded? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let natural = readDimensions(url)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelEdge,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Decoded(cgImage: cgImage, naturalSize: natural)
    }

    /// The size an image draws at inside `width`: its natural size, scaled
    /// down to fit the measure and never up past it.
    static func fit(_ natural: NSSize, width: CGFloat) -> NSSize {
        guard natural.width > width, natural.width > 0 else { return natural }
        let scale = width / natural.width
        return NSSize(width: width, height: (natural.height * scale).rounded())
    }
}
