import AppKit
import SwiftUI
import Testing
@testable import Paper

/// Renders for review of the library's group and sort buttons, its Pinned
/// row and its folder title (.plan/library-organize.md). Like the other
/// probes they run only when `PAPER_PROBE_DIR` is set.
@MainActor
struct LibraryOrganizeProbeTests {
    private static func write(_ view: some View, _ name: String, to dir: URL, scale: CGFloat = 2) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: dir.appendingPathComponent(name))
    }

    private struct Candidate: Identifiable {
        let id: String
        let glyph: AnyView
    }

    private static func drawn(_ shape: some Shape) -> AnyView {
        AnyView(shape.stroke(ControlStyle.ink(strong: false), style: ControlStyle.stroke).frame(width: 20, height: 20))
    }

    private static func symbol(_ name: String) -> AnyView {
        AnyView(Image(systemName: name).font(.system(size: 15, weight: .regular)).foregroundStyle(ControlStyle.ink(strong: false)).frame(width: 20, height: 20))
    }

    /// Each candidate at the size it is drawn in the header, and large.
    @Test(arguments: [false, true]) func iconCandidates(dark: Bool) throws {
        guard let dir = RenderProbeTests.probeDirectory else { return }
        let groups = [
            Candidate(id: "G1 heading, cards (in use)", glyph: Self.drawn(GroupGlyph())),
            Candidate(id: "G2 stack", glyph: Self.drawn(StackGlyph())),
            Candidate(id: "G3 tiles", glyph: Self.drawn(TilesGlyph())),
            Candidate(id: "G4 system", glyph: Self.symbol("rectangle.3.group")),
            Candidate(id: "G5 system", glyph: Self.symbol("square.stack")),
        ]
        let sorts = [
            Candidate(id: "S1 lines, arrow (in use)", glyph: Self.drawn(SortGlyph())),
            Candidate(id: "S2 arrows", glyph: Self.drawn(ArrowsGlyph())),
            Candidate(id: "S3 lines", glyph: Self.drawn(LinesGlyph())),
            Candidate(id: "S4 system", glyph: Self.symbol("arrow.up.arrow.down")),
            Candidate(id: "S5 system", glyph: Self.symbol("line.3.horizontal.decrease")),
        ]
        func row(_ candidates: [Candidate]) -> some View {
            HStack(spacing: 28) {
                ForEach(candidates) { candidate in
                    VStack(spacing: 10) {
                        candidate.glyph.scaleEffect(3).frame(width: 64, height: 64)
                        candidate.glyph
                        Text(candidate.id).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .frame(width: 130)
                }
            }
        }
        let menu = [
            Candidate(id: "none", glyph: Self.drawn(CardsGlyph())),
            Candidate(id: "modified", glyph: Self.drawn(ClockGlyph())),
            Candidate(id: "created", glyph: Self.drawn(CalendarGlyph())),
            Candidate(id: "name", glyph: Self.drawn(LetterGlyph())),
            Candidate(id: "property", glyph: Self.drawn(TagGlyph())),
            Candidate(id: "pin", glyph: Self.drawn(PinGlyph())),
        ]
        let sheet = VStack(spacing: 28) { row(groups); row(sorts); row(menu) }
            .padding(28)
            .background(LibraryPalette.background)
            .environment(\.colorScheme, dark ? .dark : .light)
        try Self.write(sheet, "library-icons-\(dark ? "dark" : "light").png", to: dir)
    }

    /// The header's two ends as drawn: the folder's title at rest and
    /// under the pointer, and the controls.
    @Test(arguments: [false, true]) func header(dark: Bool) throws {
        guard let dir = RenderProbeTests.probeDirectory else { return }
        let folder = URL(fileURLWithPath: "/Users/you/notes/members", isDirectory: true)
        let view = VStack(alignment: .leading, spacing: 14) {
            HStack {
                LibraryFolderTitle(folder: folder)
                Spacer()
                LibraryControls(selectionCount: 0, grouped: false, showGroupMenu: { _ in }, showSortMenu: { _ in })
            }
            HStack {
                LibraryFolderTitle(folder: folder, hovering: true)
                Spacer()
                LibraryControls(selectionCount: 2, grouped: true, showGroupMenu: { _ in }, showSortMenu: { _ in })
            }
        }
        .padding(14)
        .frame(width: 560)
        .background(LibraryPalette.background)
        .environment(\.colorScheme, dark ? .dark : .light)
        try Self.write(view, "library-header-\(dark ? "dark" : "light").png", to: dir)
    }

    /// The page with a Pinned row over grouped notes.
    @Test(arguments: [false, true]) func pinnedRowOverGroups(dark: Bool) throws {
        guard let dir = RenderProbeTests.probeDirectory else { return }
        let root = URL(fileURLWithPath: "/tmp/library-probe/members", isDirectory: true)
        let now = Date()
        func note(_ name: String, daysAgo: Double) -> FolderListing.Note {
            FolderListing.Note(url: root.appendingPathComponent("\(name).md"), title: name, modified: now.addingTimeInterval(-daysAgo * 86_400))
        }
        var listing = FolderListing()
        // No folder card: its drop target is an AppKit view, which an
        // offscreen render cannot draw.
        listing.notes = [note("Prospective members", daysAgo: 0), note("Jeff", daysAgo: 0.1), note("Ross", daysAgo: 1), note("Mayank", daysAgo: 3), note("Criteria", daysAgo: 12)]
        let store = PinStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("pins-\(UUID().uuidString).json"))
        store.toggle(listing.notes[0].url)
        store.toggle(listing.notes[4].url)
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let defaults = UserDefaults.standard
        let before = defaults.string(forKey: LibraryGrouping.storageKey)
        defaults.set(LibraryGrouping.modified.storage, forKey: LibraryGrouping.storageKey)
        defer {
            if let before { defaults.set(before, forKey: LibraryGrouping.storageKey) } else { defaults.removeObject(forKey: LibraryGrouping.storageKey) }
        }
        let view = LibraryView(navigation: LibraryNavigation(root: root), listing: listing, scrolls: false, pinStore: store)
            .frame(width: 900, height: 1500)
            .environment(\.colorScheme, dark ? .dark : .light)
        try Self.write(view, "library-pinned-\(dark ? "dark" : "light").png", to: dir, scale: 1)
    }
}

// Candidates not chosen as the defaults; here only to be looked at.

/// Four tiles.
private struct TilesGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var path = Path()
        for x in [CGFloat(4), 13.5] {
            for y in [CGFloat(4), 13.5] {
                path.addRoundedRect(
                    in: CGRect(x: rect.minX + x * s, y: rect.minY + y * s, width: 6.5 * s, height: 6.5 * s),
                    cornerSize: CGSize(width: 2 * s, height: 2 * s), style: .continuous
                )
            }
        }
        return path
    }
}

/// Three lines, each shorter than the last.
private struct LinesGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        for (y, end) in [(CGFloat(7), CGFloat(20)), (12, 15.5), (17, 11)] {
            path.move(to: p(4, y))
            path.addLine(to: p(end, y))
        }
        return path
    }
}

/// A card with two more stacked behind it, each showing as a
/// shorter line above.
private struct StackGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(9, 3.5))
        path.addLine(to: p(15, 3.5))
        path.move(to: p(6.5, 7))
        path.addLine(to: p(17.5, 7))
        path.addRoundedRect(
            in: CGRect(x: rect.minX + 4 * s, y: rect.minY + 10.5 * s, width: 16 * s, height: 10 * s),
            cornerSize: CGSize(width: 3 * s, height: 3 * s), style: .continuous
        )
        return path
    }
}

/// An arrow up beside an arrow down.
private struct ArrowsGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(8, 19.5))
        path.addLine(to: p(8, 4.5))
        path.move(to: p(4.5, 8))
        path.addLine(to: p(8, 4.5))
        path.addLine(to: p(11.5, 8))
        path.move(to: p(16, 4.5))
        path.addLine(to: p(16, 19.5))
        path.move(to: p(12.5, 16))
        path.addLine(to: p(16, 19.5))
        path.addLine(to: p(19.5, 16))
        return path
    }
}
