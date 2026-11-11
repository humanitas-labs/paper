import AppKit
import Testing
@testable import Paper

/// Pipe tables set as a grid over the untouched source: each row conceals
/// to a line as tall as its wrapped cells, which the text view draws (#7).
@MainActor
struct TableTests {
    private static let table = """
        | Name | Count | Note |
        | :--- | ---: | :---: |
        | a | 1 | x |
        | longer name | 12345 | yy |
        """

    private func styledView(_ text: String, selectedAt location: Int = 0) -> (PaperTextView, PaperLayoutManager) {
        let textView = PaperTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        textView.string = text
        textView.syntaxStyler.apply(to: textView)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        let layoutManager = textView.layoutManager as! PaperLayoutManager
        layoutManager.ensureLayout(for: textView.textContainer!)
        return (textView, layoutManager)
    }

    // MARK: Detection

    @Test
    func aHeaderADelimiterAndRowsAreOneTable() {
        let tables = MarkdownTable.tables(in: Self.table, range: NSRange(location: 0, length: Self.table.utf16.count))
        #expect(tables.count == 1)
        let table = tables[0]
        #expect(table.columnCount == 3)
        #expect(table.alignments == [.left, .right, .center])
        #expect(table.body.count == 2)
        let text = Self.table as NSString
        #expect(table.header.cells.map { text.substring(with: $0) } == ["Name", "Count", "Note"])
        #expect(table.body[1].cells.map { text.substring(with: $0) } == ["longer name", "12345", "yy"])
        #expect(table.range == NSRange(location: 0, length: text.length))
    }

    @Test
    func aDelimiterNeedsAHeaderWithTheSameCount() {
        for text in ["| --- |\n| a |", "| a | b |\n| --- |\n| c |", "prose\n\n| --- | --- |"] {
            #expect(MarkdownTable.tables(in: text, range: NSRange(location: 0, length: text.utf16.count)).isEmpty, Comment(rawValue: text))
        }
    }

    @Test
    func outerPipesAreOptionalAndEscapedPipesAreLiteral() {
        let text = "a | b\n--|--\nc \\| d | e"
        let tables = MarkdownTable.tables(in: text, range: NSRange(location: 0, length: text.utf16.count))
        #expect(tables.count == 1)
        let table = tables[0]
        #expect(table.columnCount == 2)
        let source = text as NSString
        #expect(table.header.cells.map { source.substring(with: $0) } == ["a", "b"])
        #expect(table.body[0].cells.map { source.substring(with: $0) } == ["c \\| d", "e"])
        #expect(table.header.pipes.count == 1)
        #expect(table.header.pipes[0].before == 1)
    }

    @Test
    func rowsMayBeShortOrLongAndAQuoteLineEndsTheTable() {
        let text = "| a | b |\n| - | - |\n| c |\n| d | e | f |\n> | g | h |"
        let tables = MarkdownTable.tables(in: text, range: NSRange(location: 0, length: text.utf16.count))
        #expect(tables.count == 1)
        #expect(tables[0].body.map(\.cells.count) == [1, 3])
    }

    @Test
    func pipesTakeTheWhitespaceAroundThem() {
        let text = "|  a  |b|"
        let row = MarkdownTable.row(in: text as NSString, line: NSRange(location: 0, length: text.utf16.count))!
        let source = text as NSString
        #expect(row.pipes.map { source.substring(with: $0.range) } == ["|  ", "  |", "|"])
        #expect(row.pipes.map(\.before) == [0, 1, 2])
        #expect(row.cells.map { source.substring(with: $0) } == ["a", "b"])
    }

    @Test
    func fencedAndCommentedRowsAreNotTables() throws {
        let text = "```\n| a |\n| - |\n```\n<!--\n| a |\n| - |\n-->"
        let (textView, _) = styledView(text)
        let storage = try #require(textView.textStorage)
        #expect(storage.attribute(.tableRow, at: 4, effectiveRange: nil) == nil, "fenced")
        let commented = (text as NSString).range(of: "| a |", options: .backwards)
        #expect(storage.attribute(.tableRow, at: commented.location, effectiveRange: nil) == nil, "commented")
    }

    // MARK: Styling

    private static let page = "intro\n\n" + table + "\n\nafter"

    private func rowRect(_ layoutManager: PaperLayoutManager, at location: Int) -> NSRect {
        layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.glyphIndexForCharacter(at: location), effectiveRange: nil
        )
    }

    @Test
    func everyRowCarriesItsMarkAndTheSourceIsUntouched() throws {
        let text = Self.page
        let (textView, layoutManager) = styledView(text)
        let storage = try #require(textView.textStorage)
        let table = try #require(MarkdownTable.tables(in: text, range: NSRange(location: 0, length: text.utf16.count)).first)
        let header = try #require(storage.attribute(.tableRow, at: table.header.line.location, effectiveRange: nil) as? TableRowMark)
        #expect(header.kind == .header)
        #expect(header.layout.columns.count == 3)
        #expect(header.layout.rows.map { $0.map(\.text.string) } == [["Name", "Count", "Note"], ["a", "1", "x"], ["longer name", "12345", "yy"]])
        let delimiter = try #require(storage.attribute(.tableRow, at: table.delimiter.line.location, effectiveRange: nil) as? TableRowMark)
        #expect(delimiter.kind == .delimiter)
        #expect(layoutManager.isConcealed(characterAt: table.body[0].line.location + 1))
        #expect(storage.attribute(.tableRow, at: 0, effectiveRange: nil) == nil)
        #expect(textView.string == text, "styling never edits the source")
    }

    @Test
    func aConcealedRowIsAsTallAsItsCellsAndTheDelimiterFoldsToTheRule() throws {
        let text = Self.page
        let (textView, layoutManager) = styledView(text)
        let storage = try #require(textView.textStorage)
        let table = try #require(MarkdownTable.tables(in: text, range: NSRange(location: 0, length: text.utf16.count)).first)
        for row in [table.header, table.delimiter] + table.body {
            let mark = try #require(storage.attribute(.tableRow, at: row.line.location, effectiveRange: nil) as? TableRowMark)
            #expect(rowRect(layoutManager, at: row.line.location).height == mark.height + mark.trailing)
        }
        #expect(rowRect(layoutManager, at: table.delimiter.line.location).height == Appearance.thematicBreakThickness)
    }

    @Test
    func theCaretEnteringARowMovesNothing() throws {
        let text = Self.page
        let table = try #require(MarkdownTable.tables(in: text, range: NSRange(location: 0, length: text.utf16.count)).first)
        let after = (text as NSString).range(of: "after").location
        let (_, resting) = styledView(text)
        let restingTops = (table.rows.map(\.line.location) + [after]).map { rowRect(resting, at: $0).minY }
        for row in table.rows {
            let (_, layoutManager) = styledView(text, selectedAt: row.line.location + 2)
            #expect(!layoutManager.isConcealed(characterAt: row.line.location + 1), "the row shows its source")
            let tops = (table.rows.map(\.line.location) + [after]).map { rowRect(layoutManager, at: $0).minY }
            #expect(tops == restingTops)
        }
    }

    @Test
    func aTableWiderThanTheMeasureWrapsItsCells() throws {
        let long = String(repeating: "several words that go on ", count: 8)
        let text = "| Key | Meaning | Notes |\n| --- | --- | --- |\n| a | \(long)| \(long)|\n"
        let (textView, layoutManager) = styledView(text + "\nafter")
        let storage = try #require(textView.textStorage)
        let table = try #require(MarkdownTable.tables(in: text, range: NSRange(location: 0, length: text.utf16.count)).first)
        let mark = try #require(storage.attribute(.tableRow, at: table.body[0].line.location, effectiveRange: nil) as? TableRowMark)
        #expect(mark.layout.width <= MarkdownSyntaxStyler.measure(of: textView))
        #expect(mark.height > 3 * TableMeasure.lineHeight, "the long cells wrap")
        #expect(mark.layout.columns[0].width < mark.layout.columns[1].width)
        // The row is one line however long its source.
        var effective = NSRange()
        _ = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.glyphIndexForCharacter(at: table.body[0].line.location), effectiveRange: &effective
        )
        #expect(NSMaxRange(effective) >= layoutManager.glyphIndexForCharacter(at: NSMaxRange(table.body[0].line) - 1))
    }

    @Test
    func aClickOnACellLandsInThatCellsSource() throws {
        let text = Self.page
        let (textView, layoutManager) = styledView(text)
        let storage = try #require(textView.textStorage)
        let table = try #require(MarkdownTable.tables(in: text, range: NSRange(location: 0, length: text.utf16.count)).first)
        let row = table.body[1]
        let mark = try #require(storage.attribute(.tableRow, at: row.line.location, effectiveRange: nil) as? TableRowMark)
        let rect = rowRect(layoutManager, at: row.line.location)
        let origin = textView.textContainerOrigin
        let padding = textView.textContainer!.lineFragmentPadding
        for (column, cell) in row.cells.enumerated() {
            let band = mark.layout.columns[column]
            let point = NSPoint(x: origin.x + padding + band.x + band.width / 2, y: origin.y + rect.midY)
            let index = try #require(textView.tableSourceIndex(at: point))
            #expect(index >= cell.location && index <= NSMaxRange(cell), "column \(column)")
            #expect(textView.characterIndexForInsertion(at: point) == index)
        }
        // A row showing its source answers like any other text.
        textView.setSelectedRange(NSRange(location: row.line.location + 2, length: 0))
        layoutManager.ensureLayout(for: textView.textContainer!)
        let revealed = rowRect(layoutManager, at: row.line.location)
        #expect(textView.tableSourceIndex(at: NSPoint(x: origin.x + padding + 4, y: origin.y + revealed.midY)) == nil)
    }

    @Test
    func cellsDropTheirSyntaxAndTheHeaderIsHeavier() throws {
        let text = "| **Bold** head | b |\n| --- | --- |\n| a `code` \\| pipe | [link](https://example.com/a/long/path) |\n"
        let (textView, _) = styledView(text + "\nafter")
        let storage = try #require(textView.textStorage)
        let mark = try #require(storage.attribute(.tableRow, at: 0, effectiveRange: nil) as? TableRowMark)
        #expect(mark.layout.rows.map { $0.map(\.text.string) } == [["Bold head", "b"], ["a code | pipe", "link"]])
        let head = mark.layout.rows[0][1].text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(head == Appearance.tableHeaderFont())
        let link = mark.layout.rows[1][1]
        #expect(link.sourceOffsets.first == (text as NSString).range(of: "link").location)
    }

    @Test
    func columnsShareTheRoomByWhatTheyWant() {
        #expect(TableLayout.fit(natural: [50, 80], minimum: [20, 30], room: 200) == [50, 80])
        let squeezed = TableLayout.fit(natural: [100, 900], minimum: [40, 60], room: 500)
        #expect(squeezed.reduce(0, +) <= 500)
        #expect(squeezed[0] >= 40 && squeezed[1] > squeezed[0])
        let broken = TableLayout.fit(natural: [900, 900], minimum: [400, 400], room: 300)
        #expect(broken == [150, 150])
    }

    @Test
    func anIncrementalRestyleMatchesAFullOne() throws {
        let text = Self.page
        let (textView, _) = styledView(text)
        let storage = try #require(textView.textStorage)
        let location = (text as NSString).range(of: "longer").location
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.insertText("much ", replacementRange: NSRange(location: location, length: 0))
        textView.syntaxStyler.applyEdited(to: textView)
        let (fresh, _) = styledView(textView.string)
        let full = try #require(fresh.textStorage)
        #expect(!textView.syntaxStyler.lastPassWasFull)
        #expect(storage.isEqual(to: full))
        var index = 0
        while index < min(storage.length, full.length) {
            var a = NSRange(), b = NSRange()
            let attributesA = storage.attributes(at: index, effectiveRange: &a) as NSDictionary
            let attributesB = full.attributes(at: index, effectiveRange: &b) as NSDictionary
            if !attributesA.isEqual(attributesB) || a != b {
                Issue.record("first difference at \(index) \(a) \(b): \(attributesA) vs \(attributesB)")
                break
            }
            index = max(NSMaxRange(a), NSMaxRange(b))
        }
        let mark = try #require(storage.attribute(.tableRow, at: location, effectiveRange: nil) as? TableRowMark)
        #expect(mark.layout.rows[2][0].text.string == "much longer name")
    }
}
