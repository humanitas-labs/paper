import Foundation

/// Everything the user can tune, read from `~/.config/paper/config`.
/// Values are validated and clamped on parse so a typo in the file degrades
/// to the default for that key rather than breaking the window.
struct Configuration: Equatable, Sendable {
    /// "New York" is the system serif, present on every Mac; any installed
    /// family name replaces it.
    var fontFamily = "New York"
    var fontSize: Double = 15
    var lineHeight: Double = 1.2
    var paragraphSpacing: Double = 11
    var measure: Double = 640
    /// Tracking in points added between characters; negative tightens.
    var letterSpacing: Double = -0.02
    /// Whether AppKit's font smoothing, which thickens every stem a little,
    /// is applied. Off, the default, renders glyphs at their true weight,
    /// as WebKit does.
    var fontSmoothing: Bool = false
    /// The system's continuous spelling and grammar checking, each drawn
    /// as underlines while you type. Off drops the marks as well. Grammar
    /// starts off: its marks land on prose that is fine and on Markdown
    /// that is not prose.
    var spelling: Bool = true
    var grammar: Bool = false
    /// Weights on the CSS scale, 100–900. A face with a variable weight axis
    /// takes the exact value; a static family takes its nearest face.
    var fontWeight: Double = 400
    var headingWeight: Double = 500
    /// Indent of a list item's marker (bullet, number, or task circle) from
    /// the text margin, as a multiple of the font size.
    var listIndent: Double = 0.8
    /// Corner radius in points a block image is clipped to; 0 is square.
    var imageCornerRadius: Double = 12
    /// Subfolder, relative to the document, that pasted images are written
    /// into; empty is the document's own folder. Never absolute, never
    /// escaping with `..`, so images stay with the document.
    var imagePasteDirectory: String = ""
    /// The theme's canonical name: a built-in or a file in `themes/`. Kept
    /// as written even when nothing resolves to it, so a theme file added
    /// later is picked up; `ConfigurationStore` resolves it to a `Theme`.
    var theme: String = Theme.enso.name
    /// Size of a newly opened window in points; macOS restores each window's
    /// last size after that.
    var windowWidth: Double = 1400
    var windowHeight: Double = 876
    /// The body type's size on an exported or printed page, and the
    /// text's distance from every page edge, both in points. The page is
    /// laid out fresh at that size; the window's zoom plays no part.
    var printFontSize: Double = 10
    var printMargin: Double = 64
    /// Whether to ask GitHub, once a day on launch, for the latest release
    /// and show a download icon in the welcome window when it is newer.
    /// Off never makes the request.
    var updateCheck: Bool = true
    /// Whether the menu bar carries Paper's item with the pinned documents
    /// (#77). On by default; off takes the item away.
    var menuBar: Bool = true
    /// Whether `$…$`, `$$ … $$`, and `math` fences draw as typeset math.
    /// Off leaves them as typed, and a `math` fence is a code block.
    var math: Bool = true
    /// The math typeface, one SwiftMath bundles.
    var mathFont: MathFont = .latinModern
    /// Math size as a multiple of its default: display math at 1.25× the
    /// body, inline math at the body's x-height.
    var mathScale: Double = 1
    /// Hex overrides for the theme's colours; nil inherits the theme.
    var colorOverrides = Palette.Overrides()

    /// The four required colours, as Settings binds them.
    var canvas: String? {
        get { colorOverrides.canvas }
        set { colorOverrides.canvas = newValue }
    }
    var ink: String? {
        get { colorOverrides.ink }
        set { colorOverrides.ink = newValue }
    }
    var canvasDark: String? {
        get { colorOverrides.canvasDark }
        set { colorOverrides.canvasDark = newValue }
    }
    var inkDark: String? {
        get { colorOverrides.inkDark }
        set { colorOverrides.inkDark = newValue }
    }
    /// The selection highlight, as Settings binds it; nil is the theme's
    /// tone, or the ink at 13% when the theme sets none.
    var selection: String? {
        get { colorOverrides.selection }
        set { colorOverrides.selection = newValue }
    }
    var selectionDark: String? {
        get { colorOverrides.selectionDark }
        set { colorOverrides.selectionDark = newValue }
    }
    /// The ink math draws in, as Settings binds it; nil is the theme's
    /// math ink, or the text's ink when the theme sets none.
    var mathColor: String? {
        get { colorOverrides.math }
        set { colorOverrides.math = newValue }
    }
    var mathColorDark: String? {
        get { colorOverrides.mathDark }
        set { colorOverrides.mathDark = newValue }
    }

    /// A `color.*` key and the override it sets.
    struct ColorKey: Sendable {
        let key: String
        let path: WritableKeyPath<Palette.Overrides, String?> & Sendable

        init(_ key: String, _ path: WritableKeyPath<Palette.Overrides, String?> & Sendable) {
            self.key = key
            self.path = path
        }
    }

    /// Every colour key in template order.
    static let colorKeys: [ColorKey] = [
        ColorKey("color.canvas", \.canvas),
        ColorKey("color.ink", \.ink),
        ColorKey("color.canvas.dark", \.canvasDark),
        ColorKey("color.ink.dark", \.inkDark),
        ColorKey("color.ink.muted", \.inkMuted),
        ColorKey("color.ink.quote", \.inkQuote),
        ColorKey("color.ink.label", \.inkLabel),
        ColorKey("color.selection", \.selection),
        ColorKey("color.selection.ink", \.selectionInk),
        ColorKey("color.code.background", \.codeBackground),
        ColorKey("color.rule", \.rule),
        ColorKey("color.accent", \.accent),
        ColorKey("color.math", \.math),
        ColorKey("color.ink.muted.dark", \.inkMutedDark),
        ColorKey("color.ink.quote.dark", \.inkQuoteDark),
        ColorKey("color.ink.label.dark", \.inkLabelDark),
        ColorKey("color.selection.dark", \.selectionDark),
        ColorKey("color.selection.ink.dark", \.selectionInkDark),
        ColorKey("color.code.background.dark", \.codeBackgroundDark),
        ColorKey("color.rule.dark", \.ruleDark),
        ColorKey("color.accent.dark", \.accentDark),
        ColorKey("color.math.dark", \.mathDark),
    ]

    /// The overrides applied over a resolved theme's palette.
    func palette(over base: Palette) -> Palette {
        base.applying(colorOverrides)
    }

    static let fontSizeRange: ClosedRange<Double> = 8...40
    static let lineHeightRange: ClosedRange<Double> = 1...2.5
    static let paragraphSpacingRange: ClosedRange<Double> = 0...60
    static let measureRange: ClosedRange<Double> = 320...1200
    static let letterSpacingRange: ClosedRange<Double> = -1...3
    static let weightRange: ClosedRange<Double> = 100...900
    static let imageCornerRadiusRange: ClosedRange<Double> = 0...40
    static let listIndentRange: ClosedRange<Double> = 0...4
    static let windowWidthRange: ClosedRange<Double> = 640...4000
    static let windowHeightRange: ClosedRange<Double> = 520...3000
    static let printFontSizeRange: ClosedRange<Double> = 6...18
    static let printMarginRange: ClosedRange<Double> = 18...144
    static let mathScaleRange: ClosedRange<Double> = 0.5...2

    static let didChangeNotification = Notification.Name("paper.configuration.didChange")

    /// The file Paper writes on first launch: every key, its default, and
    /// what it does. Parsing this text yields `Configuration()`.
    static let template = """
    # Paper configuration. Edits apply to open windows as you save.
    # Lines starting with # are comments. Unknown keys are ignored; invalid
    # values fall back to the default shown here. Presets are files in the
    # presets/ directory beside this one, in the same format; Settings can
    # save, apply, and delete them.

    # Body typeface and size in points. New York is the system serif and is
    # always available; any installed family name works — for example
    # Charter, Iowan Old Style, Palatino, or Georgia.
    font.family = New York
    font.size = 15

    # Body weight, 100–900 (regular is 400). New York and other variable
    # faces take any value; static families use their nearest face.
    font.weight = 400

    # Line height as a multiple of the font size, and space after a paragraph
    # in points.
    line.height = 1.2
    paragraph.spacing = 11

    # Maximum text width in points.
    measure = 640

    # Letter spacing in points added between characters (negative tightens).
    letter.spacing = -0.02

    # Font smoothing: on applies macOS's smoothing, which thickens stems a
    # little; off draws glyphs at their true weight, as Safari does.
    font.smoothing = off

    # Heading weight, 100–900, or regular, medium, semibold, or bold.
    heading.weight = 500

    # Spelling and grammar checking as you type, each on or off.
    spelling = on
    grammar = off

    # Indent of a list's bullets, numbers, and task circles from the text
    # margin, as a multiple of the font size; 0 puts them on the margin.
    list.indent = 0.8

    # Corner radius in points that a block image is clipped to; 0 is square.
    image.corner.radius = 12

    # Folder, relative to the document, that pasted and dropped images are
    # written into (for example assets). Empty is the document's own
    # folder. It is created when first needed.
    image.paste.directory =

    # Theme: enso, apple, paper, slate, mono, or spatial, or the name of a file in
    # the themes/ directory beside this one holding color.* keys like those
    # below. Each has light and dark colours; the colour overrides below
    # tune any of them. Settings can save the current colours as a theme.
    theme = enso

    # Size of new windows in points. Each window remembers its own size
    # after that.
    window.width = 1400
    window.height = 876

    # Exported and printed pages (⇧⌘E, ⌘P): the body type's size and the
    # text's distance from every page edge, in points. Lines wrap to the
    # page at that size; the window's zoom plays no part.
    print.font.size = 10
    print.margin = 64

    # Once a day on launch, ask GitHub whether a newer Paper is out and show
    # a download icon in the welcome window when there is. Off never makes
    # the request.
    update.check = on

    # A Paper item in the menu bar, beside the clock, listing the pinned
    # documents (File ▸ Pin Document), the recent ones, New, and Open.
    menu.bar = on

    # Math: $…$ in a line, $$ … $$ blocks, and ```math fences draw as
    # typeset formulas; off leaves them as typed. The typeface is one of
    # latin-modern, termes, xits, libertinus, garamond, kpmath,
    # kpmath-sans, asana, euler, fira, noto-sans, or lete-sans. The scale
    # multiplies math's size, which matches the text by default.
    math = on
    math.font = latin-modern
    math.scale = 1

    # Colour overrides as #RRGGBB. Leave a value empty to use the theme's.
    color.canvas =
    color.ink =
    color.canvas.dark =
    color.ink.dark =

    # The remaining tones are the ink at an opacity unless set here (or in a
    # theme file): muted syntax markers, bullets, and the file label; quoted
    # text; the welcome window's labels and icons; the selection highlight,
    # and the ink of selected text (unset keeps the text's own colour); the
    # code band and chip; the thematic break rule; the accent, the one
    # coloured tone, on the welcome window's update arrow; math, which
    # unset is the ink. Each has a .dark form for the dark appearance.
    color.ink.muted =
    color.ink.quote =
    color.ink.label =
    color.selection =
    color.selection.ink =
    color.code.background =
    color.rule =
    color.accent =
    color.math =
    color.ink.muted.dark =
    color.ink.quote.dark =
    color.ink.label.dark =
    color.selection.dark =
    color.selection.ink.dark =
    color.code.background.dark =
    color.rule.dark =
    color.accent.dark =
    color.math.dark =

    """

    /// Parses `key = value` lines. Whitespace around keys and values is
    /// trimmed; a value may be wrapped in single or double quotes.
    static func parse(_ text: String) -> Configuration {
        var config = Configuration()
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = unquote(line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))
            config.apply(key: key, value: value)
        }
        return config
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private mutating func apply(key: String, value: String) {
        switch key {
        case "font.family":
            if !value.isEmpty { fontFamily = value }
        case "font.size":
            fontSize = Self.number(value, in: Self.fontSizeRange) ?? fontSize
        case "line.height":
            lineHeight = Self.number(value, in: Self.lineHeightRange) ?? lineHeight
        case "paragraph.spacing":
            paragraphSpacing = Self.number(value, in: Self.paragraphSpacingRange) ?? paragraphSpacing
        case "measure":
            measure = Self.number(value, in: Self.measureRange) ?? measure
        case "letter.spacing":
            letterSpacing = Self.number(value, in: Self.letterSpacingRange) ?? letterSpacing
        case "font.smoothing":
            fontSmoothing = Self.flag(value) ?? fontSmoothing
        case "spelling":
            spelling = Self.flag(value) ?? spelling
        case "grammar":
            grammar = Self.flag(value) ?? grammar
        case "font.weight":
            fontWeight = Self.weight(value) ?? fontWeight
        case "heading.weight":
            headingWeight = Self.weight(value) ?? headingWeight
        case "list.indent":
            listIndent = Self.number(value, in: Self.listIndentRange) ?? listIndent
        case "image.corner.radius":
            imageCornerRadius = Self.number(value, in: Self.imageCornerRadiusRange) ?? imageCornerRadius
        case "image.paste.directory":
            if ImagePaste.isAcceptableDirectory(value) { imagePasteDirectory = value.trimmingCharacters(in: .whitespaces) }
        case "window.width":
            windowWidth = Self.number(value, in: Self.windowWidthRange) ?? windowWidth
        case "window.height":
            windowHeight = Self.number(value, in: Self.windowHeightRange) ?? windowHeight
        case "print.font.size":
            printFontSize = Self.number(value, in: Self.printFontSizeRange) ?? printFontSize
        case "print.margin":
            printMargin = Self.number(value, in: Self.printMarginRange) ?? printMargin
        case "update.check":
            updateCheck = Self.flag(value) ?? updateCheck
        case "menu.bar":
            menuBar = Self.flag(value) ?? menuBar
        case "math":
            math = Self.flag(value) ?? math
        case "math.font":
            mathFont = MathFont(configName: value) ?? mathFont
        case "math.scale":
            mathScale = Self.number(value, in: Self.mathScaleRange) ?? mathScale
        case "theme":
            let name = Theme.canonicalName(value)
            if !name.isEmpty { theme = name }
        default:
            if let color = Self.colorKeys.first(where: { $0.key == key }) {
                colorOverrides[keyPath: color.path] = HexColor.normalized(value)
            }
        }
    }

    /// Every key with its current value, in template order.
    var entries: [(key: String, value: String)] {
        [
            ("font.family", fontFamily),
            ("font.size", Self.format(fontSize)),
            ("font.weight", Self.format(fontWeight)),
            ("line.height", Self.format(lineHeight)),
            ("paragraph.spacing", Self.format(paragraphSpacing)),
            ("measure", Self.format(measure)),
            ("letter.spacing", Self.format(letterSpacing)),
            ("font.smoothing", fontSmoothing ? "on" : "off"),
            ("heading.weight", Self.format(headingWeight)),
            ("spelling", spelling ? "on" : "off"),
            ("grammar", grammar ? "on" : "off"),
            ("list.indent", Self.format(listIndent)),
            ("image.corner.radius", Self.format(imageCornerRadius)),
            ("image.paste.directory", imagePasteDirectory),
            ("theme", theme),
            ("window.width", Self.format(windowWidth)),
            ("window.height", Self.format(windowHeight)),
            ("print.font.size", Self.format(printFontSize)),
            ("print.margin", Self.format(printMargin)),
            ("update.check", updateCheck ? "on" : "off"),
            ("menu.bar", menuBar ? "on" : "off"),
            ("math", math ? "on" : "off"),
            ("math.font", mathFont.rawValue),
            ("math.scale", Self.format(mathScale)),
        ] + Self.colorEntries(colorOverrides)
    }

    /// The `color.*` keys with their values, empty for nil, in template
    /// order. Shared by the config file and theme files.
    static func colorEntries(_ overrides: Palette.Overrides) -> [(key: String, value: String)] {
        colorKeys.map { ($0.key, overrides[keyPath: $0.path] ?? "") }
    }

    /// Writes this configuration into existing file text, keeping comments,
    /// order, and unknown keys. Keys already present are updated in place;
    /// missing keys are appended.
    func merged(into text: String) -> String {
        var remaining = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
        var lines = text.components(separatedBy: "\n")
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            guard let value = remaining.removeValue(forKey: key) else { continue }
            lines[index] = value.isEmpty ? "\(key) =" : "\(key) = \(value)"
        }
        if !remaining.isEmpty {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            for entry in entries where remaining[entry.key] != nil {
                lines.append(entry.value.isEmpty ? "\(entry.key) =" : "\(entry.key) = \(entry.value)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// `on`/`off`, `true`/`false`, or `yes`/`no`; nil for anything else.
    private static func flag(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "on", "true", "yes": return true
        case "off", "false", "no": return false
        default: return nil
        }
    }

    private static func format(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(format: "%.2f", number)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    /// A weight as a number in `weightRange`, or one of the CSS names.
    static func weight(_ value: String) -> Double? {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "thin": return 100
        case "extralight", "ultralight": return 200
        case "light": return 300
        case "regular", "normal", "book": return 400
        case "medium": return 500
        case "semibold", "demibold": return 600
        case "bold": return 700
        case "extrabold", "heavy": return 800
        case "black": return 900
        default: return number(value, in: weightRange)
        }
    }

    private static func number(_ value: String, in range: ClosedRange<Double>) -> Double? {
        guard let parsed = Double(value), parsed.isFinite else { return nil }
        return min(max(parsed, range.lowerBound), range.upperBound)
    }
}

/// The math typefaces SwiftMath bundles, by their config names. Each
/// carries its resource name and x-height, which sizes inline math to the
/// text around it.
enum MathFont: String, CaseIterable, Sendable, Identifiable {
    case latinModern = "latin-modern"
    case termes
    case xits
    case libertinus
    case garamond
    case kpMath = "kpmath"
    case kpMathSans = "kpmath-sans"
    case asana
    case euler
    case fira
    case notoSans = "noto-sans"
    case leteSans = "lete-sans"

    var id: String { rawValue }

    /// Case, spaces, and underscores are forgiven: `Latin Modern` and
    /// `latin_modern` both name Latin Modern.
    init?(configName: String) {
        let name = configName.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        self.init(rawValue: name)
    }

    var title: String {
        switch self {
        case .latinModern: "Latin Modern"
        case .termes: "TeX Gyre Termes"
        case .xits: "XITS"
        case .libertinus: "Libertinus"
        case .garamond: "Garamond"
        case .kpMath: "KpMath"
        case .kpMathSans: "KpMath Sans"
        case .asana: "Asana"
        case .euler: "Euler"
        case .fira: "Fira Math"
        case .notoSans: "Noto Sans Math"
        case .leteSans: "Lete Sans"
        }
    }

    /// The name SwiftMath's font manager loads it by.
    var resourceName: String {
        switch self {
        case .latinModern: "latinmodern-math"
        case .termes: "texgyretermes-math"
        case .xits: "xits-math"
        case .libertinus: "LibertinusMath-Regular"
        case .garamond: "Garamond-Math"
        case .kpMath: "KpMath-Light"
        case .kpMathSans: "KpMath-Sans"
        case .asana: "Asana-Math"
        case .euler: "Euler-Math"
        case .fira: "FiraMath-Regular"
        case .notoSans: "NotoSansMath-Regular"
        case .leteSans: "LeteSansMath"
        }
    }

    /// The x-height as a fraction of the size, measured from each file.
    var xHeight: Double {
        switch self {
        case .latinModern: 0.431
        case .libertinus: 0.429
        case .kpMath, .kpMathSans: 0.442
        case .termes, .xits, .garamond, .leteSans: 0.450
        case .asana, .euler: 0.462
        case .fira: 0.527
        case .notoSans: 0.536
        }
    }
}
