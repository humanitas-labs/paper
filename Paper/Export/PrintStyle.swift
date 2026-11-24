#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A named look for exported and printed pages: `paper`, the page as the
/// editor draws it, `book`, or a file in `styles/` beside the config.
///
/// A style is `key = value` lines. Any config key in it (`font.family`,
/// `print.font.size`, `print.margin`, `line.height`, `color.*`, …) is
/// applied over the config for the length of the export, so the screen
/// never sees it. The page keys only a style has are read into `Page`:
/// alignment, hyphenation, paragraph indents, heading treatment, and page
/// numbers. A file named like a built-in replaces it, as theme files do.
struct PrintStyle: Equatable, Sendable {
    /// The canonical name: trimmed and lowercased.
    let name: String
    /// The style's lines, applied over the config by `configuration(over:)`.
    let text: String
    let page: Page

    init(name: String, text: String) {
        self.name = Self.canonicalName(name)
        self.text = text
        self.page = Page.parse(text)
    }

    static func canonicalName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// `base` with the style's config keys applied over it.
    func configuration(over base: Configuration) -> Configuration {
        base.applying(text)
    }

    /// What a style sets on the page beyond the config's own keys. The
    /// defaults are the editor's page, so a style that names none of
    /// these keys changes only what its config keys change.
    struct Page: Equatable, Sendable {
        enum Alignment: String, Sendable { case left, justified }
        enum HeadingAlignment: String, Sendable { case left, center }
        enum HeadingCase: String, Sendable { case asTyped = "as-typed", upper }

        /// `text.align`: prose paragraphs ragged right or justified.
        var alignment: Alignment = .left
        /// `hyphenation`: whether prose breaks words at line ends.
        var hyphenation = false
        /// `paragraph.indent`, in ems of the body size. Above 0, a prose
        /// paragraph that follows another is marked by this first-line
        /// indent and the blank lines between them close up, as in a
        /// book; the first paragraph after a heading or any other block
        /// is not indented. 0 keeps blank lines between paragraphs.
        var paragraphIndent: Double = 0
        /// `heading.align`: headings on the left margin or centered.
        var headingAlignment: HeadingAlignment = .left
        /// `heading.case`: headings as typed or in capitals.
        var headingCase: HeadingCase = .asTyped
        /// `heading.tracking`, in ems of each heading's size: space added
        /// between its letters.
        var headingTracking: Double = 0
        /// `page.numbers`: the page number centered at the foot of every
        /// page.
        var pageNumbers = false
        /// `page.size`: the sheet, in points. Nil is the paper chosen with
        /// `--paper` or the save panel; a size here wins over both.
        var pageSize: NSSize?

        /// Named sheets `page.size` takes, in points: the two papers and
        /// common book trims.
        static let namedSizes: [String: NSSize] = [
            "letter": NSSize(width: 612, height: 792),
            "a4": NSSize(width: 595.276, height: 841.89),
            "a5": NSSize(width: 419.528, height: 595.276),
            "trade": NSSize(width: 432, height: 648),
            "digest": NSSize(width: 396, height: 612),
            "pocket": NSSize(width: 306, height: 495),
        ]
        static let pageSideRange: ClosedRange<Double> = 144...1440

        /// A named sheet, or `W x H` with `in` (the default), `mm`, or `pt`
        /// after it: `6 x 9`, `148 x 210 mm`. Sides are clamped to 2–20 in.
        static func pageSize(_ value: String) -> NSSize? {
            if let named = namedSizes[value] { return named }
            let pattern = try! NSRegularExpression(pattern: #"^([0-9]*\.?[0-9]+)\s*[x×]\s*([0-9]*\.?[0-9]+)\s*(in|mm|pt)?$"#)
            let range = NSRange(location: 0, length: (value as NSString).length)
            guard let match = pattern.firstMatch(in: value, range: range),
                  let width = Double((value as NSString).substring(with: match.range(at: 1))),
                  let height = Double((value as NSString).substring(with: match.range(at: 2))) else { return nil }
            let unit = match.range(at: 3).location == NSNotFound ? "in" : (value as NSString).substring(with: match.range(at: 3))
            let points: Double = switch unit {
            case "mm": 72 / 25.4
            case "pt": 1
            default: 72
            }
            func side(_ length: Double) -> Double {
                min(max(length * points, pageSideRange.lowerBound), pageSideRange.upperBound)
            }
            return NSSize(width: side(width), height: side(height))
        }

        static let paragraphIndentRange: ClosedRange<Double> = 0...6
        static let headingTrackingRange: ClosedRange<Double> = -0.1...1

        /// The page keys in `text`; other keys and bad values are skipped.
        static func parse(_ text: String) -> Page {
            var page = Page()
            for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
                let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces).lowercased()
                switch key {
                case "text.align":
                    page.alignment = Alignment(rawValue: value) ?? page.alignment
                case "hyphenation":
                    page.hyphenation = flag(value) ?? page.hyphenation
                case "paragraph.indent":
                    page.paragraphIndent = number(value, in: paragraphIndentRange) ?? page.paragraphIndent
                case "heading.align":
                    page.headingAlignment = HeadingAlignment(rawValue: value == "centre" ? "center" : value) ?? page.headingAlignment
                case "heading.case":
                    page.headingCase = HeadingCase(rawValue: value) ?? page.headingCase
                case "heading.tracking":
                    page.headingTracking = number(value, in: headingTrackingRange) ?? page.headingTracking
                case "page.numbers":
                    page.pageNumbers = flag(value) ?? page.pageNumbers
                case "page.size":
                    page.pageSize = pageSize(value) ?? page.pageSize
                default:
                    break
                }
            }
            return page
        }

        private static func flag(_ value: String) -> Bool? {
            switch value {
            case "on", "true", "yes": true
            case "off", "false", "no": false
            default: nil
            }
        }

        private static func number(_ value: String, in range: ClosedRange<Double>) -> Double? {
            guard let parsed = Double(value), parsed.isFinite else { return nil }
            return min(max(parsed, range.lowerBound), range.upperBound)
        }
    }

    // MARK: - Built-in styles

    /// The page as the editor draws it, at the print size and margins.
    static let paper = PrintStyle(name: "paper", text: "")

    /// A page set like a book's: a serif at a reading size between wide
    /// margins, justified and hyphenated, paragraphs marked by indents,
    /// centered capital headings, page numbers, black on white.
    static let book = PrintStyle(name: "book", text: """
    font.family = Times New Roman
    font.weight = 400
    heading.weight = 400
    letter.spacing = 0
    line.height = 1.12
    paragraph.spacing = 2
    print.font.size = 11
    print.margin = 40
    page.size = 5 x 8
    color.canvas = #FFFFFF
    color.ink = #000000
    color.canvas.dark = #FFFFFF
    color.ink.dark = #000000
    text.align = justified
    hyphenation = on
    paragraph.indent = 1
    heading.align = center
    heading.case = upper
    heading.tracking = 0.12
    page.numbers = on
    """)

    static let builtIn: [PrintStyle] = [.paper, .book]
}

// MARK: - The page pass

extension PrintStyle.Page {
    /// Whether this page changes anything the styler set. The sheet's size
    /// is not the styler's business.
    var isEditorPage: Bool {
        var text = self
        text.pageSize = nil
        return text == PrintStyle.Page()
    }

    /// What each line of the print surface is, for the pass below.
    enum LineKind: Equatable { case blank, heading, prose, other }

    /// Sets the style's page on a print surface the styler has just
    /// styled. Runs on the print surface only, after the styler, so the
    /// editor's paragraphs are never touched.
    @MainActor
    func apply(to textView: some StyledSurface) {
        guard !isEditorPage, let storage = textView.surfaceStorage, storage.length > 0 else { return }
        let lines = Self.lines(of: storage)
        let em = Appearance.bodySize
        storage.beginEditing()
        defer { storage.endEditing() }

        func previousNonBlank(before index: Int) -> Int? {
            var cursor = index - 1
            while cursor >= 0, lines[cursor].kind == .blank { cursor -= 1 }
            return cursor >= 0 ? cursor : nil
        }
        func nextNonBlank(after index: Int) -> Int? {
            var cursor = index + 1
            while cursor < lines.count, lines[cursor].kind == .blank { cursor += 1 }
            return cursor < lines.count ? cursor : nil
        }

        for (index, line) in lines.enumerated() {
            switch line.kind {
            case .prose:
                let style = Self.mutableStyle(at: line.range.location, in: storage)
                if alignment == .justified { style.alignment = .justified }
                if hyphenation { style.hyphenationFactor = 1 }
                if paragraphIndent > 0 {
                    // A new paragraph after a prose one takes the indent; a
                    // hard-wrapped line continuing one does not.
                    if let previous = previousNonBlank(before: index), lines[previous].kind == .prose, previous < index - 1 {
                        style.firstLineHeadIndent = CGFloat(paragraphIndent) * em
                    }
                    if let next = nextNonBlank(after: index), lines[next].kind == .prose {
                        style.paragraphSpacing = 0
                    }
                }
                storage.addAttribute(.paragraphStyle, value: style, range: line.range)
            case .blank:
                guard paragraphIndent > 0,
                      let previous = previousNonBlank(before: index), lines[previous].kind == .prose,
                      let next = nextNonBlank(after: index), lines[next].kind == .prose else { continue }
                Self.closeUp(line.range, in: storage)
            case .heading:
                applyHeading(line.range, in: storage)
            case .other:
                continue
            }
        }
    }

    private func applyHeading(_ line: NSRange, in storage: NSTextStorage) {
        if headingAlignment == .center {
            let style = Self.mutableStyle(at: line.location, in: storage)
            style.alignment = .center
            storage.addAttribute(.paragraphStyle, value: style, range: line)
        }
        guard headingCase == .upper || headingTracking != 0 else { return }
        let text = storage.string as NSString
        var end = NSMaxRange(line)
        while end > line.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
        // The visible characters: not the concealed marker, not a link's
        // concealed destination.
        var visible: [NSRange] = []
        storage.enumerateAttributes(in: NSRange(location: line.location, length: end - line.location)) { attributes, range, _ in
            if attributes[.concealable] == nil { visible.append(range) }
        }
        guard let last = visible.last else { return }
        for range in visible {
            if headingTracking != 0, let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
                storage.addAttribute(.kern, value: CGFloat(headingTracking) * font.pointSize, range: range)
            }
            guard headingCase == .upper else { continue }
            // One capital for one character, drawn in its place: the source
            // is untouched, and a letter whose capital is longer (ß) stays.
            storage.addAttribute(.ligature, value: 0, range: range)
            for location in range.location..<NSMaxRange(range) {
                let character = text.substring(with: NSRange(location: location, length: 1))
                let upper = character.uppercased()
                guard upper != character, upper.utf16.count == 1 else { continue }
                storage.addAttribute(.glyphSubstitute, value: upper, range: NSRange(location: location, length: 1))
            }
        }
        // Tracking after the last letter would push a centered heading off
        // center by that much.
        if headingTracking != 0, last.length > 0 {
            storage.addAttribute(.kern, value: 0, range: NSRange(location: NSMaxRange(last) - 1, length: 1))
        }
    }

    /// A blank line between two prose paragraphs takes no height.
    private static func closeUp(_ line: NSRange, in storage: NSTextStorage) {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 0.01
        style.maximumLineHeight = 0.01
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        storage.addAttributes([.paragraphStyle: style, .font: NSFont.systemFont(ofSize: 0.01)], range: line)
    }

    private static func mutableStyle(at location: Int, in storage: NSTextStorage) -> NSMutableParagraphStyle {
        let current = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        return (current?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
    }

    /// Every line with its kind, read from the styler's attributes so
    /// code, quotes, lists, tables, images, math, and breaks are told
    /// apart exactly as the styler told them apart.
    static func lines(of storage: NSTextStorage) -> [(range: NSRange, kind: LineKind)] {
        let text = storage.string as NSString
        var lines: [(range: NSRange, kind: LineKind)] = []
        var location = 0
        while location < text.length {
            let range = text.paragraphRange(for: NSRange(location: location, length: 0))
            lines.append((range, kind(of: range, in: storage)))
            location = NSMaxRange(range)
        }
        return lines
    }

    private static let blockKeys: [NSAttributedString.Key] = [
        .codeBlock, .blockQuote, .tableRow, .imageSource, .thematicBreak,
        .listMarker, .taskBox, .mathSource, .pageBreak,
    ]

    private static let commentLine = try! NSRegularExpression(pattern: #"^\s*<!--.*-->\s*$"#)

    private static func kind(of range: NSRange, in storage: NSTextStorage) -> LineKind {
        let text = storage.string as NSString
        let line = text.substring(with: range)
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .blank }
        var isBlock = false
        storage.enumerateAttributes(in: range) { attributes, _, stop in
            if blockKeys.contains(where: { attributes[$0] != nil }) {
                isBlock = true
                stop.pointee = true
            }
        }
        if isBlock { return .other }
        let local = NSRange(location: 0, length: (line as NSString).length)
        if MarkdownSyntaxStyler.headingPattern.firstMatch(in: line, range: local)?.range.location == 0 {
            return .heading
        }
        if commentLine.firstMatch(in: line, range: local) != nil { return .other }
        // A hard-wrapped list item's continuation hangs under its text.
        if let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
           style.headIndent > 0 {
            return .other
        }
        return .prose
    }
}
