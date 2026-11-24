import AppKit
import SwiftUI

/// How the library groups a folder's notes. Folders always come first,
/// ungrouped; only the notes below them are grouped.
enum LibraryGrouping: Hashable {
    /// As listed: folders by name, then notes newest first.
    case none
    /// Today, Yesterday, Previous 7 Days, Previous 30 Days, then by month.
    case modified
    /// By the first letter of the name, A to Z, then everything else.
    case name
    /// By a frontmatter property's value; a list by its first item.
    case property(String)

    static let storageKey = "libraryGrouping"

    init(storage: String) {
        switch storage {
        case "modified": self = .modified
        case "name": self = .name
        case let value where value.hasPrefix("property:"): self = .property(String(value.dropFirst("property:".count)))
        default: self = .none
        }
    }

    var storage: String {
        switch self {
        case .none: "none"
        case .modified: "modified"
        case .name: "name"
        case .property(let key): "property:\(key)"
        }
    }

    var title: String {
        switch self {
        case .none: "None"
        case .modified: "Date Modified"
        case .name: "Name"
        case .property(let key): key.prefix(1).uppercased() + key.dropFirst()
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
    /// The notes in groups, each group's notes in their listed order. With
    /// no grouping, one untitled group.
    static func groups(
        _ notes: [FolderListing.Note], by grouping: LibraryGrouping,
        properties: [URL: [String: String]] = [:], now: Date = Date(), calendar: Calendar = .current
    ) -> [NoteGroup] {
        switch grouping {
        case .none:
            return notes.isEmpty ? [] : [NoteGroup(id: "", title: "", notes: notes)]
        case .modified:
            return bucket(notes) { note in modifiedBucket(note.modified, now: now, calendar: calendar) }
        case .name:
            return bucket(notes) { note in
                let name = note.url.deletingPathExtension().lastPathComponent
                guard let first = name.first, first.isLetter else { return (Int.max, "#") }
                let letter = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased()
                return (Int(letter.unicodeScalars.first?.value ?? 0), letter)
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

    private static func modifiedBucket(_ date: Date, now: Date, calendar: Calendar) -> (Int, String) {
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

/// The library's controls at the top right; for now only how many cards
/// are picked. (Group and search buttons were tried here and put away;
/// the grouping and search above are kept for their return.)
struct LibraryControls: View {
    let selectionCount: Int

    var body: some View {
        HStack(spacing: 4) {
            if selectionCount > 0 {
                LibraryTitlePill(title: selectionCount == 1 ? "1 selected" : "\(selectionCount) selected")
                    .monospacedDigit()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: selectionCount > 0)
    }
}

/// A rule over two rows of three tiles: cards under a heading.
struct GroupGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * s, y: rect.minY + y * s, width: w * s, height: h * s)
        }
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 3.5 * s, y: rect.minY + 5 * s))
        path.addLine(to: CGPoint(x: rect.minX + 20.5 * s, y: rect.minY + 5 * s))
        for row in 0..<2 {
            for column in 0..<3 {
                path.addRoundedRect(
                    in: r(3.5 + CGFloat(column) * 6, 9 + CGFloat(row) * 6, 5, 4.2),
                    cornerSize: CGSize(width: 1 * s, height: 1 * s)
                )
            }
        }
        return path
    }
}

/// A small chevron pointing down.
struct ChevronGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.minY + rect.height * 0.3))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.75))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.minY + rect.height * 0.3))
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
                .font(.system(size: 13))
                .foregroundStyle(FolderCard.countInk)
                .monospacedDigit()
        }
        .padding(.leading, 2)
    }
}
