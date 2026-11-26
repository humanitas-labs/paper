import AppKit
import SwiftUI
import Testing
@testable import Paper

/// Renders for review of pictures and videos in the library and its Filter
/// button (.plan/library-media.md). Like the other probes they run only
/// when `PAPER_PROBE_DIR` is set. The cards are drawn from real files,
/// named one path to a line in `media.txt` in the probe directory.
@MainActor
struct LibraryMediaProbeTests {
    private static func write(_ view: some View, _ name: String, to dir: URL, scale: CGFloat = 2) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: dir.appendingPathComponent(name))
    }

    private static func mediaFiles(in dir: URL) -> [URL] {
        let list = (try? String(contentsOf: dir.appendingPathComponent("media.txt"), encoding: .utf8)) ?? ""
        return list.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    /// Each file as a card, filled and fitted, beside a note card, so the
    /// two treatments can be compared on the same pictures.
    @Test(arguments: [false, true]) func mediaCards(dark: Bool) async throws {
        guard let dir = RenderProbeTests.probeDirectory else { return }
        let files = Self.mediaFiles(in: dir)
        try #require(!files.isEmpty, "media.txt names no files")
        var rows: [(name: String, fill: MediaPicture.Entry?, fit: MediaPicture.Entry?, kind: LibraryKind)] = []
        for url in files {
            let kind = try #require(LibraryKind.of(url))
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let fill = await MediaPicture.entry(for: MediaPicture.key(for: url, modified: modified, fills: true))
            let fit = await MediaPicture.entry(for: MediaPicture.key(for: url, modified: modified, fills: false))
            rows.append((url.lastPathComponent, fill, fit, kind))
        }
        func card(_ row: (name: String, fill: MediaPicture.Entry?, fit: MediaPicture.Entry?, kind: LibraryKind), fills: Bool) -> some View {
            let entry = fills ? row.fill : row.fit
            return MediaCard(
                item: FolderListing.Note(url: URL(fileURLWithPath: "/tmp/\(row.name)"), title: row.name, modified: Date()),
                kind: row.kind, picture: entry?.image.map { Image(nsImage: $0) }, duration: entry?.duration, fills: fills
            )
            .modifier(NoteShadow())
            .frame(width: 180)
        }
        let note = NoteCard(note: FolderListing.Note(url: URL(fileURLWithPath: "/tmp/note.md"), title: "A note, for scale", modified: Date()))
            .modifier(NoteShadow())
            .frame(width: 180)
        let sheet = VStack(alignment: .leading, spacing: 26) {
            ForEach(["Fill (cropped to the card)", "Fit (whole, on the card's ground)"], id: \.self) { title in
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LibraryPalette.secondaryLabel)
                    HStack(alignment: .top, spacing: 18) {
                        note
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in card(row, fills: title.hasPrefix("Fill")) }
                    }
                }
            }
        }
        .padding(32)
        .background(LibraryPalette.background)
        .environment(\.colorScheme, dark ? .dark : .light)
        try Self.write(sheet, "library-media-cards-\(dark ? "dark" : "light").png", to: dir)
    }

    /// The header with the Filter button, at rest and with a filter on,
    /// and the Filter menu's glyphs.
    @Test(arguments: [false, true]) func filterHeader(dark: Bool) throws {
        guard let dir = RenderProbeTests.probeDirectory else { return }
        let folder = URL(fileURLWithPath: "/Users/you/renaissance/Swipe", isDirectory: true)
        let glyphs = HStack(spacing: 22) {
            ForEach(LibraryFilter.allCases, id: \.self) { choice in
                VStack(spacing: 6) {
                    choice.glyph.stroke(ControlStyle.ink(strong: false), style: ControlStyle.stroke).frame(width: 20, height: 20)
                    Text(choice.title).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 6) {
                KindGlyph().stroke(ControlStyle.ink(strong: false), style: ControlStyle.stroke).frame(width: 20, height: 20)
                Text("Kind").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        let view = VStack(alignment: .leading, spacing: 14) {
            HStack {
                LibraryFolderTitle(folder: folder)
                Spacer()
                LibraryControls(selectionCount: 0, grouped: false, showGroupMenu: { _ in }, showSortMenu: { _ in })
            }
            HStack {
                LibraryFolderTitle(folder: folder)
                Spacer()
                LibraryControls(selectionCount: 0, grouped: false, filtered: true, showGroupMenu: { _ in }, showSortMenu: { _ in })
            }
            glyphs.padding(.top, 8)
        }
        .padding(14)
        .frame(width: 600)
        .background(LibraryPalette.background)
        .environment(\.colorScheme, dark ? .dark : .light)
        try Self.write(view, "library-filter-\(dark ? "dark" : "light").png", to: dir)
    }

    /// Scrolls a real library window over the folder named in `perf.txt`
    /// in the probe directory, at a steady fast rate, and writes how many
    /// display frames the main thread kept up with to `scroll-perf.txt`.
    /// A frame is missed when the display link's callback, which runs on
    /// the main thread, comes later than one and a half frames after the
    /// last: the main thread was busy through a refresh.
    @Test func scrollFrameTimes() async throws {
        guard let dir = RenderProbeTests.probeDirectory,
              let path = try? String(contentsOf: dir.appendingPathComponent("perf.txt"), encoding: .utf8)
        else { return }
        let folder = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let navigation = LibraryNavigation(root: folder)
        navigation.window = window
        let host = NSHostingView(rootView: LibraryView(navigation: navigation))
        host.sizingOptions = []
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .seconds(3))

        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        let scroll = try #require(find(host))
        let meter = ScrollMeter(scroll: scroll, window: window)
        var report = "folder: \(folder.path)\nitems: \((try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? 0)\n"
        report += "document height: \(Int(scroll.documentView?.frame.height ?? 0)) pt, viewport \(Int(scroll.contentView.bounds.height)) pt\n\n"
        report += "screen: \(window.screen?.localizedName ?? "?"), max \(window.screen?.maximumFramesPerSecond ?? 0) fps\n"
        report += "idle baseline (no scrolling): \(await meter.run(pointsPerFrame: 0))\n\n"
        for (name, speed) in [("cold, down (thumbnails being made)", 30.0), ("warm, up", -30.0), ("warm, down", 30.0), ("warm, up, fast fling", -80.0), ("warm, down, slow", 8.0)] {
            let result = await meter.run(pointsPerFrame: speed)
            report += "\(name): \(result)\n"
        }
        try report.write(to: dir.appendingPathComponent("scroll-perf.txt"), atomically: true, encoding: .utf8)
    }

    /// Opens a picture from a real library window in Quick Look and closes
    /// it, and writes how the main thread's frames went through each to
    /// `quicklook-perf.txt`: the zoom is the panel's, but it runs in this
    /// process, and a busy main thread shows as frames in it.
    @Test func quickLookFrameTimes() async throws {
        guard let dir = RenderProbeTests.probeDirectory,
              let path = try? String(contentsOf: dir.appendingPathComponent("perf.txt"), encoding: .utf8)
        else { return }
        let folder = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let navigation = LibraryNavigation(root: folder)
        navigation.window = window
        let host = NSHostingView(rootView: LibraryView(navigation: navigation))
        host.sizingOptions = []
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .seconds(3))
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        let media = names.map { folder.appendingPathComponent($0) }.filter { LibraryKind.of($0) == .image }
        let target = try #require(media.first { $0.pathExtension == "jpg" } ?? media.first)
        let tile = window.convertToScreen(NSRect(x: 300, y: 400, width: 123, height: 123))
        let watch = FrameWatch(window: window)
        var report = "picture: \(target.lastPathComponent)\n"
        report += "idle: \(await watch.run(seconds: 1) {})\n"
        for round in 1...3 {
            let among = round == 1 ? media : round == 2 ? [target] : Array(media.prefix(40))
            report += "open \(round) (\(among.count) items): \(await watch.run(seconds: 1.5) { LibraryPreview.shared.show(target, among: among) { _ in tile } })\n"
            report += "close \(round): \(await watch.run(seconds: 1.5) { LibraryPreview.shared.close() })\n"
        }
        try report.write(to: dir.appendingPathComponent("quicklook-perf.txt"), atomically: true, encoding: .utf8)
    }
}

/// Watches the main thread's frames for a while after something is done.
@MainActor
private final class FrameWatch: NSObject {
    let window: NSWindow
    private var stamps: [CFTimeInterval] = []
    private var busy: [(at: CFTimeInterval, took: CFTimeInterval)] = []
    private var tick: CFTimeInterval?
    private var began: CFTimeInterval = 0

    init(window: NSWindow) { self.window = window }

    func run(seconds: Double, _ action: () -> Void) async -> String {
        stamps = []
        busy = []
        tick = nil
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let tick = self.tick else { return }
                self.busy.append((tick - self.began, CACurrentMediaTime() - tick))
                self.tick = nil
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        began = CACurrentMediaTime()
        let started = CACurrentMediaTime()
        action()
        let acted = CACurrentMediaTime() - started
        try? await Task.sleep(for: .seconds(seconds))
        link.invalidate()
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        let gaps = zip(stamps.dropFirst(), stamps).map { ($1 - began, $0 - $1) }
        let longGaps = gaps.filter { $0.1 > 0.025 }.map { String(format: "%.0f ms at %.2f s", $0.1 * 1000, $0.0) }
        let heavy = busy.filter { $0.took > 0.008 }.map { String(format: "%.0f ms at %.2f s", $0.took * 1000, $0.at) }
        return String(format: "the call took %.1f ms; %d frames; ", acted * 1000, stamps.count)
            + "gaps over 25 ms: [\(longGaps.joined(separator: ", "))]; work over 8 ms: [\(heavy.joined(separator: ", "))]"
    }

    @objc private func step(_ link: CADisplayLink) {
        stamps.append(CACurrentMediaTime())
        tick = CACurrentMediaTime()
    }
}

/// Drives a scroll view from a display link and keeps each frame's time.
@MainActor
private final class ScrollMeter: NSObject {
    let scroll: NSScrollView
    let window: NSWindow
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var interval: CFTimeInterval = 0
    private var speed: CGFloat = 0
    private var done: CheckedContinuation<Void, Never>?
    /// The main thread's work for each frame: from the display's tick to
    /// the run loop next going idle, which is after the frame is committed.
    private var busy: [CFTimeInterval] = []
    private var tick: CFTimeInterval?
    private var observer: CFRunLoopObserver?

    init(scroll: NSScrollView, window: NSWindow) {
        self.scroll = scroll
        self.window = window
    }

    /// Scrolls from where it is to the end in the direction of
    /// `pointsPerFrame`, and says how the frames went.
    func run(pointsPerFrame: Double) async -> String {
        stamps = []
        busy = []
        tick = nil
        speed = pointsPerFrame
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let tick = self.tick else { return }
                self.busy.append(CACurrentMediaTime() - tick)
                self.tick = nil
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        await withCheckedContinuation { done = $0 }
        if let observer = self.observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        guard stamps.count > 2, interval > 0, !busy.isEmpty else { return "no frames" }
        let work = busy.sorted()
        func at(_ q: Double) -> Double { work[min(work.count - 1, Int(Double(work.count) * q))] * 1000 }
        let over120 = work.filter { $0 > 1.0 / 120 }.count
        let over60 = work.filter { $0 > 1.0 / 60 }.count
        let summary = String(
            format: "work per frame median %.1f ms, p95 %.1f, p99 %.1f, worst %.1f; over 8.3 ms: %d of %d (%.1f%%); over 16.7 ms: %d",
            at(0.5), at(0.95), at(0.99), (work.last ?? 0) * 1000, over120, work.count, 100 * Double(over120) / Double(work.count), over60
        )
        let deltas = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        let total = stamps.last! - stamps.first!
        let expected = Int((total / interval).rounded())
        let missed = deltas.reduce(0) { $0 + max(0, Int(($1 / interval).rounded()) - 1) }
        let hitches = deltas.filter { $0 > interval * 1.5 }.count
        let sorted = deltas.sorted()
        let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        let median = sorted[sorted.count / 2]
        return summary + String(
            format: "\n      [link says %.0f Hz, median frame %.1f ms (%.0f fps), %d of %d frames (%.1f%%), %d hitches, %d frames missed, worst %.1f ms, p99 %.1f ms, %.1f s]",
            1 / interval, median * 1000, 1 / median, deltas.count, expected, 100 * Double(deltas.count) / Double(max(expected, 1)),
            hitches, missed, (sorted.last ?? 0) * 1000, p99 * 1000, total
        )
    }

    @objc private func step(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        tick = CACurrentMediaTime()
        interval = link.targetTimestamp - link.timestamp
        let clip = scroll.contentView
        let limit = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
        let next = min(max(clip.bounds.origin.y + speed, 0), limit)
        let ended = speed == 0 ? stamps.count > 360 : (next == clip.bounds.origin.y || stamps.count > 4000)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: next))
        scroll.reflectScrolledClipView(clip)
        if ended {
            link.invalidate()
            self.link = nil
            done?.resume()
            done = nil
        }
    }
}
