import AppKit

extension NSAttributedString.Key {
    /// Marks one row paragraph of a pipe table, terminator included; the
    /// value is its `TableRowMark`. Off the active paragraph the row's
    /// source conceals to an empty line as tall as the mark says, and the
    /// text view draws the row's cells there.
    static let tableRow = NSAttributedString.Key("paper.tableRow")
}

/// One cell as it draws: the styled text with its concealed syntax
/// removed, and the way back to the source.
struct TableCell: Equatable {
    var text: NSAttributedString
    /// The source index of each UTF-16 unit of `text`, plus one last entry
    /// for the cell's end, so a caret offset in the drawn text maps to a
    /// character in the file.
    var sourceOffsets: [Int]
}

/// A pipe table set as a grid: column positions and widths fitted to the
/// measure, and each row's cells with the height their wrapped text needs.
/// Equal by content, so a restyle that builds the same table again leaves
/// the storage equal to a full pass.
final class TableLayout: NSObject {
    struct Column: Equatable {
        var x: CGFloat
        var width: CGFloat
    }

    let columns: [Column]
    /// The header's cells first, then each body row's. A short row holds
    /// fewer cells than there are columns.
    let rows: [[TableCell]]
    /// The height of each row in `rows`, padding included.
    let rowHeights: [CGFloat]
    let padding: CGFloat
    /// From the first column's leading edge to the last one's trailing edge.
    let width: CGFloat

    @MainActor
    init(rows: [[TableCell]], columnCount: Int, available: CGFloat) {
        let gutter = Appearance.tableGutter
        let padding = Appearance.tableRowPadding
        let room = max(available - gutter * CGFloat(max(columnCount - 1, 0)), CGFloat(columnCount))

        var natural = [CGFloat](repeating: 0, count: columnCount)
        var minimum = [CGFloat](repeating: 0, count: columnCount)
        for row in rows {
            for (column, cell) in row.prefix(columnCount).enumerated() {
                let measured = TableMeasure.widths(of: cell.text)
                natural[column] = max(natural[column], measured.natural)
                minimum[column] = max(minimum[column], measured.minimum)
            }
        }
        let widths = Self.fit(natural: natural, minimum: minimum, room: room)

        var columns: [Column] = []
        var x: CGFloat = 0
        for width in widths {
            columns.append(Column(x: x, width: width))
            x += width + gutter
        }
        self.columns = columns
        self.rows = rows
        self.padding = padding
        self.width = max(x - gutter, 0)
        self.rowHeights = rows.map { row in
            var tallest = TableMeasure.lineHeight
            for (column, cell) in row.prefix(columnCount).enumerated() {
                tallest = max(tallest, TableMeasure.height(of: cell.text, width: widths[column]))
            }
            return tallest + 2 * padding
        }
    }

    /// Column widths for `room`. Every column gets its natural width when
    /// they fit. Otherwise each keeps at least its longest word, capped at
    /// half the room so one long URL cannot starve the rest, and the room
    /// left over goes to the columns in proportion to what they still
    /// want. When the longest words alone do not fit, the room is shared
    /// in proportion to them and words break.
    static func fit(natural: [CGFloat], minimum: [CGFloat], room: CGFloat) -> [CGFloat] {
        guard natural.reduce(0, +) > room else { return natural }
        let floors = zip(natural, minimum).map { min($0, $1, room / 2) }
        let floorTotal = floors.reduce(0, +)
        guard floorTotal < room else {
            return floors.map { ($0 / floorTotal * room).rounded(.down) }
        }
        let wants = zip(natural, floors).map { $0 - $1 }
        let wantTotal = wants.reduce(0, +)
        guard wantTotal > 0 else { return floors }
        return zip(floors, wants).map { ($0 + (room - floorTotal) * $1 / wantTotal).rounded(.down) }
    }

    /// The column whose band, out to the middle of the gutters beside it,
    /// holds `x` (measured from the table's leading edge).
    func column(at x: CGFloat) -> Int? {
        guard !columns.isEmpty else { return nil }
        for (index, column) in columns.enumerated().reversed() where index > 0 {
            let previous = columns[index - 1]
            if x >= (previous.x + previous.width + column.x) / 2 { return index }
        }
        return 0
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TableLayout else { return false }
        return columns == other.columns && rowHeights == other.rowHeights && rows == other.rows
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(columns.count)
        hasher.combine(rows.count)
        hasher.combine(width)
        return hasher.finalize()
    }
}

/// What a table row's paragraph carries: the table's layout, which of its
/// rows this is, and the height the row holds whether its source shows or
/// not.
final class TableRowMark: NSObject {
    enum Kind { case header, delimiter, body }

    let layout: TableLayout
    let kind: Kind
    /// The index into `layout.rows`; unused on the delimiter row.
    let row: Int
    /// The row's rendered height: the drawn cells with their padding, or
    /// the hairline's thickness on the delimiter row.
    let height: CGFloat
    /// The paragraph spacing after the table, carried by its last row.
    let trailing: CGFloat

    init(layout: TableLayout, kind: Kind, row: Int, height: CGFloat, trailing: CGFloat) {
        self.layout = layout
        self.kind = kind
        self.row = row
        self.height = height
        self.trailing = trailing
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TableRowMark else { return false }
        return kind == other.kind && row == other.row && height == other.height
            && trailing == other.trailing && layout.isEqual(other.layout)
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(row)
        hasher.combine(height)
        return hasher.finalize()
    }
}

/// Cell measurement, cached by the styled text: an edit inside a table
/// restyles every row, and only the cell that changed measures again. A
/// change of font or size makes different strings, so stale entries are
/// never read; the caches empty themselves when they grow large.
@MainActor
enum TableMeasure {
    private struct HeightKey: Hashable {
        var text: NSAttributedString
        var width: CGFloat
    }

    private static var widthCache: [NSAttributedString: (natural: CGFloat, minimum: CGFloat)] = [:]
    private static var heightCache: [HeightKey: CGFloat] = [:]
    private static let limit = 20_000
    private static let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    /// One line of a cell, so an empty row is still a row.
    static var lineHeight: CGFloat { Appearance.tableLineHeight }

    /// The cell's width on one line, and the width of its longest word.
    static func widths(of text: NSAttributedString) -> (natural: CGFloat, minimum: CGFloat) {
        guard text.length > 0 else { return (0, 0) }
        if let cached = widthCache[text] { return cached }
        // A point of slack: a width rounded down by a hair would wrap the
        // last word of a cell that fits.
        let natural = (text.size().width + 1).rounded(.up)
        var minimum: CGFloat = 0
        let string = text.string as NSString
        var start = 0
        for index in 0...string.length {
            let breaks = index == string.length || string.character(at: index) == 0x20
            guard breaks else { continue }
            if index > start {
                let word = text.attributedSubstring(from: NSRange(location: start, length: index - start))
                minimum = max(minimum, (word.size().width + 1).rounded(.up))
            }
            start = index + 1
        }
        if widthCache.count > limit { widthCache.removeAll() }
        widthCache[text] = (natural, min(minimum, natural))
        return (natural, min(minimum, natural))
    }

    /// The height the cell takes wrapped to `width`.
    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0, width > 0 else { return 0 }
        let key = HeightKey(text: text, width: width)
        if let cached = heightCache[key] { return cached }
        let bounds = text.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: options
        )
        let height = bounds.height.rounded(.up)
        if heightCache.count > limit { heightCache.removeAll() }
        heightCache[key] = height
        return height
    }

    /// Draws the cell wrapped to the rect's width, from its top edge.
    static func draw(_ text: NSAttributedString, in rect: NSRect) {
        guard text.length > 0 else { return }
        text.draw(with: rect, options: options)
    }

    /// The caret offset in `text`, wrapped to `width`, nearest `point`
    /// (measured from the cell's top-left corner).
    static func offset(in text: NSAttributedString, width: CGFloat, at point: NSPoint) -> Int {
        guard text.length > 0, width > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        guard point.y < used.maxY else { return text.length }
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(
            for: NSPoint(x: point.x, y: max(point.y, 0)), in: container,
            fractionOfDistanceThroughGlyph: &fraction
        )
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return min(fraction > 0.5 ? index + 1 : index, text.length)
    }
}
