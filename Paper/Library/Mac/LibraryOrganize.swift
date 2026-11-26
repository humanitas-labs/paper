import AppKit
import SwiftUI

/// How the library groups a folder's notes. Folders always come first,
/// ungrouped; only the notes below them are grouped.
enum LibraryGrouping: Hashable {
    /// As listed: folders by name, then notes newest first.
    case none
    /// Today, Yesterday, Previous 7 Days, Previous 30 Days, then by month.
    case modified
    /// The same runs, by the day the file was made.
    case created
    /// By the first letter of the name, A to Z, then everything else.
    case name
    /// Notes, then pictures, then videos, then sounds.
    case kind
    /// By a frontmatter property's value; a list by its first item.
    case property(String)

    static let storageKey = "libraryGrouping"

    init(storage: String) {
        switch storage {
        case "modified": self = .modified
        case "created": self = .created
        case "name": self = .name
        case "kind": self = .kind
        case let value where value.hasPrefix("property:"): self = .property(String(value.dropFirst("property:".count)))
        default: self = .none
        }
    }

    var storage: String {
        switch self {
        case .none: "none"
        case .modified: "modified"
        case .created: "created"
        case .name: "name"
        case .kind: "kind"
        case .property(let key): "property:\(key)"
        }
    }

    var title: String {
        switch self {
        case .none: "None"
        case .modified: "Date Modified"
        case .created: "Date Created"
        case .name: "Name"
        case .kind: "Kind"
        case .property(let key): key.prefix(1).uppercased() + key.dropFirst()
        }
    }
}

/// The order of a folder's notes, and of the notes inside each group.
enum LibrarySort: String, CaseIterable {
    /// Newest change first, as the folder is listed.
    case modified
    /// Newest file first.
    case created
    /// A to Z by file name, numbers in their natural order.
    case name

    static let storageKey = "librarySort"

    init(storage: String) { self = LibrarySort(rawValue: storage) ?? .modified }

    var title: String {
        switch self {
        case .modified: "Date Modified"
        case .created: "Date Created"
        case .name: "Name"
        }
    }
}

/// Which cards the page shows, by kind. Folders always show.
enum LibraryFilter: String, CaseIterable {
    case all, notes, images, videos, audio

    static let storageKey = "libraryFilter"

    init(storage: String) { self = LibraryFilter(rawValue: storage) ?? .all }

    var title: String {
        switch self {
        case .all: "All"
        case .notes: "Notes"
        case .images: "Images"
        case .videos: "Videos"
        case .audio: "Audio"
        }
    }

    func admits(_ url: URL) -> Bool {
        switch self {
        case .all: true
        case .notes: LibraryKind.of(url) == .note
        case .images: LibraryKind.of(url) == .image
        case .videos: LibraryKind.of(url) == .video
        case .audio: LibraryKind.of(url) == .audio
        }
    }

    var glyph: AnyShape {
        switch self {
        case .all: AnyShape(CardsGlyph())
        case .notes: AnyShape(PageGlyph())
        case .images: AnyShape(PictureGlyph())
        case .videos: AnyShape(FilmGlyph())
        case .audio: AnyShape(WaveGlyph())
        }
    }

    /// Said where the cards would be, when the folder has none of the kind.
    var emptyMessage: String {
        switch self {
        case .all: "No notes here yet."
        case .notes: "No notes here."
        case .images: "No images here."
        case .videos: "No videos here."
        case .audio: "No audio here."
        }
    }
}

/// A run of notes under one heading.
struct NoteGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let notes: [FolderListing.Note]
}

enum LibraryOrganize {
    /// Everything from `anchor` to `end` in `order`, both included,
    /// whichever comes first; nil when either is not there.
    static func run(from anchor: URL, to end: URL, in order: [URL]) -> Set<URL>? {
        guard let first = order.firstIndex(of: anchor), let last = order.firstIndex(of: end) else { return nil }
        return Set(order[min(first, last)...max(first, last)])
    }

    /// The notes in groups, each group's notes in their listed order. With
    /// no grouping, one untitled group.
    static func groups(
        _ notes: [FolderListing.Note], by grouping: LibraryGrouping,
        properties: [URL: [String: String]] = [:], created: [URL: Date] = [:],
        now: Date = Date(), calendar: Calendar = .current
    ) -> [NoteGroup] {
        switch grouping {
        case .none:
            return notes.isEmpty ? [] : [NoteGroup(id: "", title: "", notes: notes)]
        case .modified:
            return bucket(notes) { note in dateBucket(note.modified, now: now, calendar: calendar) }
        case .created:
            // A note whose date is not read yet goes by its last change.
            return bucket(notes) { note in
                dateBucket(created[note.url.standardizedFileURL] ?? note.modified, now: now, calendar: calendar)
            }
        case .name:
            return bucket(notes) { note in
                let name = note.url.deletingPathExtension().lastPathComponent
                guard let first = name.first, first.isLetter else { return (Int.max, "#") }
                let letter = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased()
                return (Int(letter.unicodeScalars.first?.value ?? 0), letter)
            }
        case .kind:
            return bucket(notes) { note in
                switch LibraryKind.of(note.url) ?? .note {
                case .note: (0, "Notes")
                case .image: (1, "Images")
                case .video: (2, "Videos")
                case .audio: (3, "Audio")
                }
            }
        case .property(let key):
            // Values in natural order, the notes without one last.
            let values = Set(notes.compactMap { properties[$0.url.standardizedFileURL]?[key] })
            let ordered = values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let rank = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) })
            return bucket(notes) { note in
                guard let value = properties[note.url.standardizedFileURL]?[key] else { return (Int.max, "No \(key)") }
                return (rank[value] ?? 0, value)
            }
        }
    }

    /// The notes in the order asked for. Notes that tie, and notes whose
    /// creation date is not read yet, keep the order they came in.
    static func sorted(
        _ notes: [FolderListing.Note], by sort: LibrarySort, created: [URL: Date] = [:]
    ) -> [FolderListing.Note] {
        switch sort {
        case .modified:
            return stable(notes) { $0.modified > $1.modified }
        case .created:
            func date(_ note: FolderListing.Note) -> Date { created[note.url.standardizedFileURL] ?? note.modified }
            return stable(notes) { date($0) > date($1) }
        case .name:
            func name(_ note: FolderListing.Note) -> String { note.url.deletingPathExtension().lastPathComponent }
            return stable(notes) { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        }
    }

    private static func stable(
        _ notes: [FolderListing.Note], by before: (FolderListing.Note, FolderListing.Note) -> Bool
    ) -> [FolderListing.Note] {
        notes.enumerated().sorted { a, b in
            if before(a.element, b.element) { return true }
            if before(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The pinned notes apart from the rest, each in the order given.
    static func split(
        _ notes: [FolderListing.Note], pinned: (URL) -> Bool
    ) -> (pinned: [FolderListing.Note], rest: [FolderListing.Note]) {
        var result: (pinned: [FolderListing.Note], rest: [FolderListing.Note]) = ([], [])
        for note in notes {
            if pinned(note.url) { result.pinned.append(note) } else { result.rest.append(note) }
        }
        return result
    }

    /// The properties worth grouping by: those some note in the folder
    /// has, most used first, at most `limit`. A title is each note's own.
    static func groupableKeys(_ properties: [URL: [String: String]], limit: Int = 8) -> [String] {
        var counts: [String: Int] = [:]
        for values in properties.values {
            for key in values.keys where key.lowercased() != "title" { counts[key, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }

    /// Whether a card answers the search: every word of the query is in
    /// its file name or its title, in any case and with any accents.
    static func matches(_ query: String, name: String, title: String? = nil) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = title.map { "\(name) \($0)" } ?? name
        return words.allSatisfy { haystack.localizedStandardContains($0) }
    }

    private static func bucket(_ notes: [FolderListing.Note], key: (FolderListing.Note) -> (Int, String)) -> [NoteGroup] {
        var order: [(rank: Int, title: String)] = []
        var members: [String: [FolderListing.Note]] = [:]
        for note in notes {
            let (rank, title) = key(note)
            if members[title] == nil { order.append((rank, title)) }
            members[title, default: []].append(note)
        }
        return order
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.title < $1.title }
            .map { NoteGroup(id: $0.title, title: $0.title, notes: members[$0.title] ?? []) }
    }

    private static func dateBucket(_ date: Date, now: Date, calendar: Calendar) -> (Int, String) {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch days {
        case ..<1: return (0, "Today")
        case 1: return (1, "Yesterday")
        case 2..<7: return (2, "Previous 7 Days")
        case 7..<30: return (3, "Previous 30 Days")
        default:
            let parts = calendar.dateComponents([.year, .month], from: date)
            let year = parts.year ?? 0, month = parts.month ?? 0
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.setLocalizedDateFormatFromTemplate(year == calendar.component(.year, from: now) ? "MMMM" : "MMMM yyyy")
            // Newest month first.
            return (4 + (100_000 - (year * 12 + month)), formatter.string(from: date))
        }
    }
}

/// When each note's file was made, as the file system has it. A clone or
/// a sync makes the file anew, so the date is then that day's.
enum NoteDates {
    static func created(_ urls: [URL]) -> [URL: Date] {
        var dates: [URL: Date] = [:]
        for var url in urls {
            // Read from the disk, not from what the URL last remembered.
            url.removeAllCachedResourceValues()
            if let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate {
                dates[url.standardizedFileURL] = date
            }
        }
        return dates
    }
}

/// The top-level properties in a note's frontmatter, read from its head.
enum NoteProperties {
    /// Enough of the file for any frontmatter worth grouping by.
    static let headBytes = 4096

    static func read(_ url: URL) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headBytes) else { return [:] }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// `key: value` lines between the opening and closing `---`. A list,
    /// inline or as `- item` lines, gives its first item; quotes go.
    static func parse(_ text: String) -> [String: String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        guard lines.first == "---" else { return [:] }
        lines.removeFirst()
        var values: [String: String] = [:]
        var pending: String?
        for line in lines {
            if line == "---" || line == "..." { return values }
            if let key = pending {
                let item = line.trimmingCharacters(in: .whitespaces)
                if item.hasPrefix("- ") {
                    let value = clean(String(item.dropFirst(2)))
                    if !value.isEmpty { values[key] = value }
                    pending = nil
                    continue
                }
                if line.first?.isWhitespace == true { continue }
                pending = nil
            }
            guard line.first?.isWhitespace == false, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.hasPrefix("#"), !key.hasPrefix("-") else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty { pending = key; continue }
            if value.hasPrefix("[") {
                value = String(value.dropFirst().prefix { $0 != "]" }.split(separator: ",").first ?? "")
            }
            let cleaned = clean(value)
            if !cleaned.isEmpty { values[key] = cleaned }
        }
        // No closing line: not frontmatter.
        return [:]
    }

    private static func clean(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespaces)
        if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }
}

// MARK: Controls

/// The library's controls at the top right: how many cards are picked,
/// then how the notes are grouped and sorted and which kinds show. Bare glyphs, without a
/// ground; each opens its menu under itself.
struct LibraryControls: View {
    let selectionCount: Int
    /// Whether the notes are in groups now: the glyph is drawn darker.
    let grouped: Bool
    /// Whether a filter hides some kinds now: the glyph is drawn darker.
    var filtered = false
    /// Open a menu under the button's frame, in global space.
    let showGroupMenu: (CGRect) -> Void
    let showSortMenu: (CGRect) -> Void
    var showFilterMenu: (CGRect) -> Void = { _ in }
    @State private var groupFrame = CGRect.zero
    @State private var sortFrame = CGRect.zero
    @State private var filterFrame = CGRect.zero

    var body: some View {
        HStack(spacing: 4) {
            if selectionCount > 0 {
                LibraryTitlePill(title: selectionCount == 1 ? "1 selected" : "\(selectionCount) selected")
                    .monospacedDigit()
                    .padding(.trailing, 6)
                    .transition(.opacity)
            }
            // The system's symbols, as Andrew chose. Group darkens while in
            // use; Filter fills its circle while a filter is on.
            ControlButton(label: "Group") {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ControlStyle.ink(strong: grouped))
                    .frame(width: 20, height: 20)
            } action: { showGroupMenu(groupFrame) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { groupFrame = $0 }
            ControlButton(label: "Sort") {
                SortGlyph().stroke(ControlStyle.ink(strong: false), style: ControlStyle.stroke).frame(width: 20, height: 20)
            } action: { showSortMenu(sortFrame) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sortFrame = $0 }
            ControlButton(label: "Filter") {
                Image(systemName: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ControlStyle.ink(strong: filtered))
                    .frame(width: 20, height: 20)
            } action: { showFilterMenu(filterFrame) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { filterFrame = $0 }
        }
        .animation(.easeOut(duration: 0.15), value: selectionCount > 0)
    }
}

enum ControlStyle {
    static func ink(strong: Bool) -> Color { Color.primary.opacity(strong ? 0.9 : 0.62) }
    static var stroke: StrokeStyle { StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round) }
}

struct ControlButton<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 7)
                .frame(minWidth: 34, minHeight: 30)
                // The title pill's ground, so the glyph reads over the
                // pictures that scroll under it; darker under the pointer.
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.07 : 0))
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(LibraryPalette.background))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Group: a short heading over two note cards, as a group is drawn on
/// the page.
struct GroupGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(4.5, 4.5))
        path.addLine(to: p(11, 4.5))
        for x in [CGFloat(4), 13.25] {
            path.addRoundedRect(
                in: CGRect(x: rect.minX + x * s, y: rect.minY + 8.5 * s, width: 6.75 * s, height: 11.5 * s),
                cornerSize: CGSize(width: 2.1 * s, height: 2.1 * s), style: .continuous
            )
        }
        return path
    }
}

/// No grouping: the two cards alone, without a heading.
struct CardsGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var path = Path()
        for x in [CGFloat(4), 13.25] {
            path.addRoundedRect(
                in: CGRect(x: rect.minX + x * s, y: rect.minY + 5 * s, width: 6.75 * s, height: 14 * s),
                cornerSize: CGSize(width: 2.1 * s, height: 2.1 * s), style: .continuous
            )
        }
        return path
    }
}

/// Sort: three shortening lines beside an arrow down.
struct SortGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        for (y, end) in [(CGFloat(6), CGFloat(12.5)), (12, 10.5), (18, 8)] {
            path.move(to: p(3.5, y))
            path.addLine(to: p(end, y))
        }
        path.move(to: p(17.5, 4.5))
        path.addLine(to: p(17.5, 19.5))
        path.move(to: p(13.9, 15.9))
        path.addLine(to: p(17.5, 19.5))
        path.addLine(to: p(21.1, 15.9))
        return path
    }
}

/// A clock at ten past: the date a note last changed.
struct ClockGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.addEllipse(in: CGRect(x: rect.minX + 3.5 * s, y: rect.minY + 3.5 * s, width: 17 * s, height: 17 * s))
        path.move(to: p(12, 7.5))
        path.addLine(to: p(12, 12))
        path.addLine(to: p(15.2, 14))
        return path
    }
}

/// A calendar leaf: the day a note was made.
struct CalendarGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: rect.minX + 4 * s, y: rect.minY + 5.5 * s, width: 16 * s, height: 14.5 * s),
            cornerSize: CGSize(width: 3 * s, height: 3 * s), style: .continuous
        )
        path.move(to: p(4, 10.2))
        path.addLine(to: p(20, 10.2))
        for x in [CGFloat(8.5), 15.5] {
            path.move(to: p(x, 3.5))
            path.addLine(to: p(x, 7))
        }
        return path
    }
}

/// A capital A: by name.
struct LetterGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(5.5, 19.5))
        path.addLine(to: p(12, 4.5))
        path.addLine(to: p(18.5, 19.5))
        path.move(to: p(8, 14.2))
        path.addLine(to: p(16, 14.2))
        return path
    }
}

/// A tag with its hole: by a property.
struct TagGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(4, 6.5))
        path.addQuadCurve(to: p(6.5, 4), control: p(4, 4))
        path.addLine(to: p(11.6, 4))
        path.addLine(to: p(19.6, 12))
        path.addQuadCurve(to: p(19.6, 14.4), control: p(20.8, 13.2))
        path.addLine(to: p(14.4, 19.6))
        path.addQuadCurve(to: p(12, 19.6), control: p(13.2, 20.8))
        path.addLine(to: p(4, 11.6))
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: rect.minX + 7.3 * s, y: rect.minY + 7.3 * s, width: 2.4 * s, height: 2.4 * s))
        return path
    }
}

extension LibraryGrouping {
    /// The glyph beside the choice in the grouping's menu.
    var glyph: AnyShape {
        switch self {
        case .none: AnyShape(CardsGlyph())
        case .modified: AnyShape(ClockGlyph())
        case .created: AnyShape(CalendarGlyph())
        case .name: AnyShape(LetterGlyph())
        case .kind: AnyShape(KindGlyph())
        case .property: AnyShape(TagGlyph())
        }
    }
}

extension LibrarySort {
    var glyph: AnyShape {
        switch self {
        case .modified: AnyShape(ClockGlyph())
        case .created: AnyShape(CalendarGlyph())
        case .name: AnyShape(LetterGlyph())
        }
    }
}

/// A pushpin, upright: a cap, a body that flares, and the needle.
struct PinGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(8, 4))
        path.addLine(to: p(16, 4))
        path.move(to: p(9.5, 4))
        path.addLine(to: p(9.5, 9.5))
        path.addLine(to: p(6.5, 14))
        path.addLine(to: p(17.5, 14))
        path.addLine(to: p(14.5, 9.5))
        path.addLine(to: p(14.5, 4))
        path.move(to: p(12, 14))
        path.addLine(to: p(12, 20.5))
        return path
    }
}

/// A check: done.
struct CheckGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(5, 12.5))
        path.addLine(to: p(10, 17.5))
        path.addLine(to: p(19, 7))
        return path
    }
}

/// A lens with its handle to the lower right.
struct SearchGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var path = Path()
        path.addEllipse(in: CGRect(x: rect.minX + 4 * s, y: rect.minY + 4 * s, width: 12.5 * s, height: 12.5 * s))
        path.move(to: CGPoint(x: rect.minX + 14.6 * s, y: rect.minY + 14.6 * s))
        path.addLine(to: CGPoint(x: rect.minX + 20 * s, y: rect.minY + 20 * s))
        return path
    }
}

/// A group's heading over its cards: the name, then how many.
struct NoteGroupHeading: View {
    let group: NoteGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(group.title)
                .font(.system(size: 15, weight: .regular))
                .tracking(-0.022 * 15)
                .foregroundStyle(FolderCard.nameInk)
            Text("\(group.notes.count)")
                // Proportional figures, set as close as the name: in
                // fixed-width ones a 1 stands apart, and 612 read as 6 1 2.
                .font(.system(size: 13))
                .tracking(-0.022 * 13)
                .foregroundStyle(FolderCard.countInk)
        }
        .padding(.leading, 2)
    }
}
