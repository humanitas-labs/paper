import Foundation

/// Return inside a list item continues the list: the next line starts with
/// the item's indent, any block-quote prefix, and the next marker. Return on
/// an item with no text removes the marker instead, ending the list the way
/// Apple Notes does. The decision is pure text-in, edit-out; the text view
/// applies it through the undo-aware editing path.
enum ListContinuation {
    struct Edit: Equatable {
        /// Characters to replace.
        let range: NSRange
        /// Replacement text.
        let replacement: String
        /// Selection after the replacement.
        let selection: NSRange
    }

    /// A line that is only indent, quote prefix, and marker — an item the
    /// writer left empty before pressing Return.
    private static let emptyItemPattern = try! NSRegularExpression(
        pattern: #"^([\t ]*(?:>[\t ]?)*)([-+*]|\d+[A-Za-z]?[.)]|(?=[ivx]{2,}[.)])x{0,3}(?:ix|iv|v?i{0,3})[.)]|(?=[IVX]{2,}[.)])X{0,3}(?:IX|IV|V?I{0,3})[.)]|[A-Za-z][.)])(?:[\t ]+\[[ xX]\])?[\t ]*$"#
    )

    /// The edit Return should perform at `selection`, or nil when ordinary
    /// newline insertion is right.
    static func edit(in text: NSString, selection: NSRange) -> Edit? {
        guard selection.location <= text.length,
              NSMaxRange(selection) <= text.length else { return nil }
        let paragraph = text.paragraphRange(for: NSRange(location: selection.location, length: 0))
        var content = paragraph
        while content.length > 0 {
            let last = text.character(at: NSMaxRange(content) - 1)
            guard last == 0x0A || last == 0x0D else { break }
            content.length -= 1
        }

        // The empty-item check comes first: an empty item also matches the
        // list pattern (it styles as a list before any text is typed), and
        // Return on it must end the list, not continue it.
        if selection.length == 0,
           selection.location == NSMaxRange(content),
           let match = emptyItemPattern.firstMatch(in: text as String, range: content),
           match.range == content {
            // Return on an empty item takes the marker away and leaves the
            // caret on the now-plain line.
            return Edit(
                range: content,
                replacement: "",
                selection: NSRange(location: content.location, length: 0)
            )
        }

        if let match = MarkdownSyntaxStyler.listMarkerPattern.firstMatch(in: text as String, range: content),
           match.range.location == content.location {
            // The caret must sit in the item's text; Return inside the
            // indent or marker is an ordinary line break.
            guard selection.location >= NSMaxRange(match.range) else { return nil }
            let marker = text.substring(with: match.range(at: 1))
            let prefix = text.substring(
                with: NSRange(
                    location: match.range.location,
                    length: match.range(at: 1).location - match.range.location
                )
            )
            var gap = text.substring(with: match.range(at: 2))
            // A task item continues as an open task, with the box's own
            // gap (or one space, when Return came right after the box).
            if match.range(at: 3).location != NSNotFound {
                let boxGap = match.range(at: 4).length > 0 ? text.substring(with: match.range(at: 4)) : " "
                gap += "[ ]" + boxGap
            }
            // Splitting an item mid-line hands the tail to the new item;
            // the spaces that separated the halves would double the marker
            // gap, so the edit takes them too.
            var range = selection
            while NSMaxRange(range) < NSMaxRange(content) {
                let character = text.character(at: NSMaxRange(range))
                guard character == 0x20 || character == 0x09 else { break }
                range.length += 1
            }
            let replacement = "\n" + prefix + nextMarker(after: marker, previous: previousMarker(in: text, before: paragraph)) + gap
            return Edit(
                range: range,
                replacement: replacement,
                selection: NSRange(location: range.location + replacement.utf16.count, length: 0)
            )
        }

        return nil
    }

    /// One level of list nesting in the source.
    static let indentUnit = "  "

    /// The edit Tab (`outdent: false`) or Shift-Tab (`outdent: true`) should
    /// perform at `selection`: the caret's list item shifts one indent level
    /// as a whole, marker included. Nil outside a list item — a plain tab is
    /// right there — and nil when there is nothing left to outdent.
    static func indent(in text: NSString, selection: NSRange, outdent: Bool) -> Edit? {
        guard selection.location <= text.length,
              NSMaxRange(selection) <= text.length else { return nil }
        let paragraph = text.paragraphRange(for: selection)
        var content = paragraph
        while content.length > 0 {
            let last = text.character(at: NSMaxRange(content) - 1)
            guard last == 0x0A || last == 0x0D else { break }
            content.length -= 1
        }
        guard let match = MarkdownSyntaxStyler.listMarkerPattern.firstMatch(in: text as String, range: content),
              match.range.location == content.location else { return nil }

        if !outdent {
            return Edit(
                range: NSRange(location: paragraph.location, length: 0),
                replacement: Self.indentUnit,
                selection: NSRange(
                    location: selection.location + Self.indentUnit.utf16.count,
                    length: selection.length
                )
            )
        }

        // Outdent removes one tab or up to an indent unit's spaces from the
        // line start, whatever the writer indented with.
        var removed = 0
        if content.length > 0, text.character(at: content.location) == 0x09 {
            removed = 1
        } else {
            while removed < Self.indentUnit.utf16.count,
                  content.length > removed,
                  text.character(at: content.location + removed) == 0x20 {
                removed += 1
            }
        }
        guard removed > 0 else { return nil }
        return Edit(
            range: NSRange(location: paragraph.location, length: removed),
            replacement: "",
            selection: NSRange(
                location: max(paragraph.location, selection.location - removed),
                length: selection.length
            )
        )
    }

    /// The marker of the list item on the line before `paragraph`, if that
    /// line is one; it tells a Roman `i.` from the letter after `h.`.
    private static func previousMarker(in text: NSString, before paragraph: NSRange) -> String? {
        guard paragraph.location > 0 else { return nil }
        let previous = text.paragraphRange(for: NSRange(location: paragraph.location - 1, length: 0))
        guard let match = MarkdownSyntaxStyler.listMarkerPattern.firstMatch(in: text as String, range: previous),
              match.range.location == previous.location else { return nil }
        return text.substring(with: match.range(at: 1))
    }

    /// The marker for the item after one marked `marker`: unordered markers
    /// repeat, numbers count up, Roman numerals count up in Roman (`ii.` →
    /// `iii.`), and a letter advances instead, whether it suffixes a number
    /// (`1a)` → `1b)`) or stands alone (`a.` → `b.`). A lone `i`, `v`, or
    /// `x` is a letter or a numeral by its neighbor (`previous`, the marker
    /// on the line above): `i.` counts as Roman unless it follows `h.`, and
    /// `v.` or `x.` only when it follows a numeral.
    static func nextMarker(after marker: String, previous: String? = nil) -> String {
        switch marker {
        case "-", "*", "+":
            return marker
        default:
            let delimiter = String(marker.suffix(1))
            var body = String(marker.dropLast())
            if let value = romanValue(body, previous: previous.map { String($0.dropLast()) }) {
                let next = roman(value + 1)
                return (body.first!.isUppercase ? next.uppercased() : next) + delimiter
            }
            if let letter = body.last, letter.isLetter {
                body.removeLast()
                return body + nextLetter(after: letter) + delimiter
            }
            let number = Int(body) ?? 0
            return String(number + 1) + delimiter
        }
    }

    /// The value of `body` read as a Roman numeral, or nil when it reads as
    /// a letter or is not a numeral at all.
    private static func romanValue(_ body: String, previous: String?) -> Int? {
        guard let value = parseRoman(body) else { return nil }
        guard body.count == 1 else { return value }
        switch body.lowercased() {
        case "i": return previous?.lowercased() == "h" ? nil : value
        case "v", "x": return previous.flatMap(parseRoman) != nil ? value : nil
        default: return nil
        }
    }

    private static let numerals: [(Int, String)] = [
        (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
        (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
    ]

    /// `value` in lowercase Roman numerals.
    static func roman(_ value: Int) -> String {
        var rest = value
        var result = ""
        for (amount, numeral) in numerals {
            while rest >= amount {
                result += numeral
                rest -= amount
            }
        }
        return result
    }

    /// The value of a canonical Roman numeral in one case, or nil.
    static func parseRoman(_ text: String) -> Int? {
        guard !text.isEmpty, text == text.lowercased() || text == text.uppercased() else { return nil }
        let lower = text.lowercased()
        guard lower.allSatisfy({ "ivxlcdm".contains($0) }) else { return nil }
        var total = 0
        var rest = Substring(lower)
        for (amount, numeral) in numerals {
            while rest.hasPrefix(numeral) {
                total += amount
                rest = rest.dropFirst(numeral.count)
            }
        }
        guard rest.isEmpty, roman(total) == lower else { return nil }
        return total
    }

    private static func nextLetter(after letter: Character) -> String {
        guard letter != "z", letter != "Z",
              let scalar = letter.unicodeScalars.first,
              let next = Unicode.Scalar(scalar.value + 1) else { return String(letter) }
        return String(Character(next))
    }
}
