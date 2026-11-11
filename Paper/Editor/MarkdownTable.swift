import Foundation

/// A pipe table read off the source: a header row, a delimiter row, and
/// the body rows that follow without a break. Pure geometry over the
/// string; nothing here knows about fonts or attributes. The styler turns
/// a table into concealed pipes with reserved widths, so the source is
/// never rewritten.
///
/// GFM rules kept: the outer pipes are optional, `\|` is a literal pipe,
/// a pipe inside a code span still splits cells, the delimiter row fixes
/// the column count and the header must match it, and body rows may be
/// shorter or longer (extra cells are outside the table).
struct MarkdownTable: Equatable {
    enum Alignment: Equatable {
        case left, center, right
    }

    struct Row: Equatable {
        /// The line without its terminator.
        var line: NSRange
        /// Trimmed cell contents, in column order. May be empty ranges.
        var cells: [NSRange]
        /// Each pipe with the whitespace around it, in source order. `before`
        /// is the index of the cell the pipe precedes; the trailing pipe
        /// precedes `cells.count`.
        var pipes: [(range: NSRange, pipe: Int, before: Int)]

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.line == rhs.line && lhs.cells == rhs.cells
                && lhs.pipes.map(\.range) == rhs.pipes.map(\.range)
                && lhs.pipes.map(\.before) == rhs.pipes.map(\.before)
        }
    }

    var header: Row
    var delimiter: Row
    var body: [Row]
    var alignments: [Alignment]

    var columnCount: Int { alignments.count }
    var rows: [Row] { [header] + body }

    /// From the header's first character to the last body row's line end.
    var range: NSRange {
        let last = body.last ?? delimiter
        return NSRange(location: header.line.location, length: NSMaxRange(last.line) - header.line.location)
    }

    /// Every table in `range`, skipping any row that starts inside one of
    /// `excluding` (fenced code, comments).
    static func tables(in source: String, range: NSRange, excluding: [NSRange] = []) -> [MarkdownTable] {
        let text = source as NSString
        var tables: [MarkdownTable] = []
        var location = range.location
        let end = NSMaxRange(range)
        var pending: Row?

        func line(at location: Int) -> (paragraph: NSRange, line: NSRange) {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            var line = paragraph
            while line.length > 0 {
                let last = text.character(at: NSMaxRange(line) - 1)
                guard last == 0x0A || last == 0x0D else { break }
                line.length -= 1
            }
            return (paragraph, line)
        }

        while location < end {
            let (paragraph, lineRange) = line(at: location)
            location = NSMaxRange(paragraph)
            let excluded = excluding.contains { NSLocationInRange(lineRange.location, $0) }
            guard !excluded, let header = pending, let delimiter = row(in: text, line: lineRange),
                  let alignments = alignments(of: delimiter, in: text), header.cells.count == alignments.count
            else {
                pending = excluded ? nil : row(in: text, line: lineRange)
                continue
            }
            pending = nil

            var body: [Row] = []
            while location < end {
                let (next, nextLine) = line(at: location)
                guard !excluding.contains(where: { NSLocationInRange(nextLine.location, $0) }),
                      let row = row(in: text, line: nextLine)
                else { break }
                body.append(row)
                location = NSMaxRange(next)
            }
            tables.append(MarkdownTable(header: header, delimiter: delimiter, body: body, alignments: alignments))
        }
        return tables
    }

    /// The line as a table row: at least one unescaped pipe, not a quote
    /// line, and something other than a lone pipe.
    static func row(in text: NSString, line: NSRange) -> Row? {
        guard line.length > 0 else { return nil }
        let lineEnd = NSMaxRange(line)
        var pipes: [Int] = []
        var index = line.location
        var first: Int?
        while index < lineEnd {
            let character = text.character(at: index)
            if first == nil, !isSpace(character) { first = index }
            if character == 0x7C /* | */, index == line.location || text.character(at: index - 1) != 0x5C /* \ */ {
                pipes.append(index)
            }
            index += 1
        }
        guard let first, !pipes.isEmpty, text.character(at: first) != 0x3E /* > */ else { return nil }
        var last = lineEnd - 1
        while last > first, isSpace(text.character(at: last)) { last -= 1 }

        let leading = pipes.first == first
        let trailing = pipes.last == last && (!leading || pipes.count > 1)
        guard !(leading && pipes.count == 1 && trailing) else { return nil }

        // Cell boundaries: the content between consecutive pipes, the
        // line's edges standing in for missing outer pipes.
        var boundaries: [(start: Int, end: Int)] = []
        var cursor = leading ? pipes[0] + 1 : line.location
        for pipe in pipes where !(leading && pipe == pipes[0]) {
            boundaries.append((cursor, pipe))
            cursor = pipe + 1
        }
        if !trailing { boundaries.append((cursor, lineEnd)) }
        let cells = boundaries.map { trimmed(text, from: $0.start, to: $0.end) }
        guard !cells.isEmpty, cells.count == 1 ? leading || trailing : true else { return nil }

        // Each pipe takes the whitespace on both sides, up to the
        // neighbouring cell's content or the previous pipe's run.
        var runs: [(range: NSRange, pipe: Int, before: Int)] = []
        var previousEnd = line.location
        for (offset, pipe) in pipes.enumerated() {
            let before = leading ? offset : offset + 1
            var start = pipe
            while start > previousEnd, isSpace(text.character(at: start - 1)) { start -= 1 }
            var finish = pipe + 1
            while finish < lineEnd, isSpace(text.character(at: finish)) { finish += 1 }
            runs.append((NSRange(location: start, length: finish - start), pipe, before))
            previousEnd = finish
        }
        return Row(line: line, cells: cells, pipes: runs)
    }

    /// The delimiter row's alignments, or nil when a cell is not `-+` with
    /// optional colons.
    static func alignments(of row: Row, in text: NSString) -> [Alignment]? {
        var alignments: [Alignment] = []
        for cell in row.cells {
            guard cell.length > 0 else { return nil }
            let content = text.substring(with: cell)
            let left = content.hasPrefix(":")
            let right = content.hasSuffix(":") && content.count > 1
            let dashes = content.drop(while: { $0 == ":" }).dropLast(right ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(left && right ? .center : right ? .right : .left)
        }
        return alignments.isEmpty ? nil : alignments
    }

    private static func trimmed(_ text: NSString, from start: Int, to end: Int) -> NSRange {
        var start = start
        var end = end
        while start < end, isSpace(text.character(at: start)) { start += 1 }
        while end > start, isSpace(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func isSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }
}
