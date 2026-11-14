import Foundation

/// One heading the outline lists. Ranges are UTF-16 offsets into the
/// source, as NSString and the text view use them.
struct OutlineHeading: Equatable, Sendable, Identifiable {
    /// 1...6, the number of `#`s.
    let level: Int
    /// The heading's text with inline markup stripped, for display.
    let title: String
    /// The whole heading line, without its line break.
    let range: NSRange
    /// The text after the marker and its gap: what the styler sets in the
    /// heading font.
    let contentRange: NSRange
    /// One heading per line, so the line's offset identifies it.
    var id: Int { range.location }
}

/// The headings of a document, read off the source the way the styler
/// reads them: the same heading pattern, and the same fenced blocks and
/// comments left out. Pure, so it runs off the main actor.
enum Outline {
    /// The headings Paper draws as headings, in document order.
    nonisolated static func headings(in source: String) -> [OutlineHeading] {
        let text = source as NSString
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return [] }
        let fences = MarkdownSyntaxStyler.fencedBlocks(in: source, range: full)
        let comments = MarkdownSyntaxStyler.commentRanges(in: source, range: full, fenced: fences)
        let excluded = (fences + comments).sorted { $0.location < $1.location }

        var headings: [OutlineHeading] = []
        var cursor = 0
        MarkdownSyntaxStyler.headingPattern.enumerateMatches(in: source, range: full) { match, _, _ in
            guard let match else { return }
            let start = match.range.location
            // Matches and blocks both run in document order, so one cursor
            // walks the blocks once.
            while cursor < excluded.count, NSMaxRange(excluded[cursor]) <= start { cursor += 1 }
            if cursor < excluded.count, NSLocationInRange(start, excluded[cursor]) { return }
            let content = match.range(at: 2)
            let title = title(fromContent: text.substring(with: content))
            guard !title.isEmpty else { return }
            headings.append(OutlineHeading(
                level: match.range(at: 1).length,
                title: title,
                range: match.range,
                contentRange: content
            ))
        }
        return headings
    }

    /// The heading whose section holds `location`: the last heading that
    /// starts at or before it, or nil before the first.
    nonisolated static func sectionIndex(containing location: Int, in headings: [OutlineHeading]) -> Int? {
        var low = 0
        var high = headings.count
        while low < high {
            let middle = (low + high) / 2
            if headings[middle].range.location <= location { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    // MARK: - Titles

    private nonisolated static let closingSequence = try! NSRegularExpression(pattern: #"(?:^|[\t ]+)#+[\t ]*$"#)
    private nonisolated static let imagePattern = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\([^)\s]+\)"#)
    private nonisolated static let referenceLinkPattern = try! NSRegularExpression(pattern: #"(?<!!)\[([^\]\n]+)\]\[[^\]\n]*\]"#)
    private nonisolated static let autolinkPattern = try! NSRegularExpression(pattern: #"<((?:https?|mailto):[^>\s]+)>"#)
    private nonisolated static let tagPattern = try! NSRegularExpression(pattern: #"</?[A-Za-z][^>\n]*>"#)
    private nonisolated static let escapePattern = try! NSRegularExpression(pattern: #"\\([!-/:-@\[-`{-~])"#)
    private nonisolated static let whitespacePattern = try! NSRegularExpression(pattern: #"\s+"#)
    /// Stands in for a code span while the other passes run, so nothing
    /// inside the span is read as markup.
    private nonisolated static let placeholder = "\u{E000}"

    /// Display text for a heading's content: a closing `#` run dropped,
    /// code spans, links, images, emphasis, strikethrough, underline, and
    /// tags reduced to their text, escapes resolved, whitespace collapsed.
    /// Inline math stays as typed.
    nonisolated static func title(fromContent content: String) -> String {
        var title = content.trimmingCharacters(in: .whitespaces)
        title = replace(closingSequence, in: title, with: "")

        // Code spans, then escapes, are set aside first: nothing inside a
        // span, and no escaped character, is markup.
        var spans: [String] = []
        title = protect(MarkdownSyntaxStyler.codePattern, in: title, spans: &spans) { inner in
            guard inner.count >= 2, inner.hasPrefix(" "), inner.hasSuffix(" ") else { return inner }
            return String(inner.dropFirst().dropLast())
        }
        title = protect(escapePattern, in: title, group: 1, spans: &spans) { $0 }

        title = replace(imagePattern, in: title, with: "$1")
        title = replace(MarkdownSyntaxStyler.linkPattern, in: title, with: "$1")
        title = replace(referenceLinkPattern, in: title, with: "$1")
        title = replace(autolinkPattern, in: title, with: "$1")
        for pattern in [
            MarkdownSyntaxStyler.strongEmphasisPattern,
            MarkdownSyntaxStyler.strongPattern,
            MarkdownSyntaxStyler.emphasisPattern,
            MarkdownSyntaxStyler.underscoreStrongPattern,
            MarkdownSyntaxStyler.underscoreEmphasisPattern,
        ] {
            title = replaceWithContent(pattern, in: title)
        }
        title = replace(MarkdownSyntaxStyler.strikethroughPattern, in: title, with: "$1")
        title = replace(MarkdownSyntaxStyler.underlinePattern, in: title, with: "$1")
        title = replace(tagPattern, in: title, with: "")

        for (index, span) in spans.enumerated() {
            title = title.replacingOccurrences(of: placeholder + String(index) + placeholder, with: span)
        }
        title = replace(whitespacePattern, in: title, with: " ")
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// Replaces each match with a placeholder token and keeps its text,
    /// as `transform` gives it, in `spans` for restoring at the end.
    private nonisolated static func protect(
        _ pattern: NSRegularExpression,
        in text: String,
        group: Int = 2,
        spans: inout [String],
        transform: (String) -> String
    ) -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            result += placeholder + String(spans.count) + placeholder
            spans.append(transform(ns.substring(with: match.range(at: group))))
            last = NSMaxRange(match.range)
        }
        return result + ns.substring(from: last)
    }

    private nonisolated static func replace(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template
        )
    }

    /// Replaces each match with whichever capture group took part: the
    /// styler's emphasis patterns hold alternatives (`***x***` or
    /// `___x___`) in separate groups.
    private nonisolated static func replaceWithContent(_ pattern: NSRegularExpression, in text: String) -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let content = (1..<match.numberOfRanges)
                .map { match.range(at: $0) }
                .first { $0.location != NSNotFound } ?? match.range
            result += ns.substring(with: content)
            last = NSMaxRange(match.range)
        }
        result += ns.substring(from: last)
        return result
    }
}
