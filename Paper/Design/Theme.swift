import Foundation

/// A theme's colours. Canvas and ink, light and dark, are required; every
/// other tone (muted punctuation, quoted text, labels, selection, the code
/// band, the thematic-break rule) is optional and derives from the ink by
/// opacity when a theme leaves it out.
struct Palette: Equatable, Sendable {
    var canvas: String
    var ink: String
    var canvasDark: String
    var inkDark: String
    var inkMuted: String?
    var inkQuote: String?
    /// Chrome labels: the welcome window's section titles and row icons.
    var inkLabel: String?
    var selection: String?
    /// Ink for selected text; nil keeps the text's own colour.
    var selectionInk: String?
    var codeBackground: String?
    var rule: String?
    /// The one coloured tone: the update arrow in the welcome window.
    /// Nil is the label ink.
    var accent: String?
    var inkMutedDark: String?
    var inkQuoteDark: String?
    var inkLabelDark: String?
    var selectionDark: String?
    var selectionInkDark: String?
    var codeBackgroundDark: String?
    var ruleDark: String?
    var accentDark: String?

    /// The colour keys of a theme file or of the config's overrides: each
    /// value is a `#RRGGBB` string or nil to inherit.
    struct Overrides: Equatable, Sendable {
        var canvas: String?
        var ink: String?
        var canvasDark: String?
        var inkDark: String?
        var inkMuted: String?
        var inkQuote: String?
        var inkLabel: String?
        var selection: String?
        var selectionInk: String?
        var codeBackground: String?
        var rule: String?
        var accent: String?
        var inkMutedDark: String?
        var inkQuoteDark: String?
        var inkLabelDark: String?
        var selectionDark: String?
        var selectionInkDark: String?
        var codeBackgroundDark: String?
        var ruleDark: String?
        var accentDark: String?

        var isEmpty: Bool { self == Overrides() }
    }

    /// `overrides` layered over this palette; nil values keep the base.
    func applying(_ o: Overrides) -> Palette {
        Palette(
            canvas: o.canvas ?? canvas,
            ink: o.ink ?? ink,
            canvasDark: o.canvasDark ?? canvasDark,
            inkDark: o.inkDark ?? inkDark,
            inkMuted: o.inkMuted ?? inkMuted,
            inkQuote: o.inkQuote ?? inkQuote,
            inkLabel: o.inkLabel ?? inkLabel,
            selection: o.selection ?? selection,
            selectionInk: o.selectionInk ?? selectionInk,
            codeBackground: o.codeBackground ?? codeBackground,
            rule: o.rule ?? rule,
            accent: o.accent ?? accent,
            inkMutedDark: o.inkMutedDark ?? inkMutedDark,
            inkQuoteDark: o.inkQuoteDark ?? inkQuoteDark,
            inkLabelDark: o.inkLabelDark ?? inkLabelDark,
            selectionDark: o.selectionDark ?? selectionDark,
            selectionInkDark: o.selectionInkDark ?? selectionInkDark,
            codeBackgroundDark: o.codeBackgroundDark ?? codeBackgroundDark,
            ruleDark: o.ruleDark ?? ruleDark,
            accentDark: o.accentDark ?? accentDark
        )
    }

    /// Every value as an override, for writing a palette out as a theme file.
    var overrides: Overrides {
        Overrides(
            canvas: canvas, ink: ink, canvasDark: canvasDark, inkDark: inkDark,
            inkMuted: inkMuted, inkQuote: inkQuote, inkLabel: inkLabel, selection: selection, selectionInk: selectionInk,
            codeBackground: codeBackground, rule: rule, accent: accent,
            inkMutedDark: inkMutedDark, inkQuoteDark: inkQuoteDark, inkLabelDark: inkLabelDark,
            selectionDark: selectionDark, selectionInkDark: selectionInkDark,
            codeBackgroundDark: codeBackgroundDark, ruleDark: ruleDark, accentDark: accentDark
        )
    }
}

extension Palette.Overrides {
    /// The overrides as `color.*` lines: the content of a theme file.
    var fileText: String {
        Configuration.colorEntries(self)
            .filter { !$0.value.isEmpty }
            .map { "\($0.key) = \($0.value)" }
            .joined(separator: "\n") + "\n"
    }
}

/// A named palette, chosen by the `theme` configuration key. The built-ins
/// ship with the app; user themes are files in `themes/` beside the config,
/// holding the same `color.*` keys, and shadow a built-in of the same name.
struct Theme: Equatable, Sendable, Identifiable {
    /// The stored name: lowercase, the file name for a user theme.
    let name: String
    let title: String
    let palette: Palette
    let isBuiltIn: Bool

    var id: String { name }

    /// The shipped default: white under a warm near-black ink. Its
    /// selection is a solid, near-black under off-white in the light
    /// appearance and the inverse in the dark; its labels are Zed's slate
    /// grey, which sits between the ink and the muted tone in both.
    static let enso = Theme(
        name: "enso", title: "Enso",
        palette: Palette(
            canvas: "#FFFFFF", ink: "#2D2B29", canvasDark: "#191B1D", inkDark: "#F4F9FA",
            inkLabel: "#68737E",
            selection: "#353535", selectionInk: "#F9F9F9",
            accent: "#24B6C9",
            inkLabelDark: "#68737E",
            selectionDark: "#F4F9FA", selectionInkDark: "#191B1D",
            accentDark: "#24B6C9"
        ),
        isBuiltIn: true
    )

    static let builtIn: [Theme] = [
        enso,
        Theme(name: "apple", title: "Apple",
              palette: Palette(canvas: "#FFFFFF", ink: "#272727", canvasDark: "#212323", inkDark: "#DDDDDD"),
              isBuiltIn: true),
        Theme(name: "paper", title: "Paper",
              palette: Palette(canvas: "#F6F3EC", ink: "#1B1916", canvasDark: "#1B1916", inkDark: "#E8E3D6"),
              isBuiltIn: true),
        Theme(name: "slate", title: "Slate",
              palette: Palette(canvas: "#F2F3F5", ink: "#1F2328", canvasDark: "#15181C", inkDark: "#D9DEE5"),
              isBuiltIn: true),
        Theme(name: "mono", title: "Mono",
              palette: Palette(canvas: "#FFFFFF", ink: "#000000", canvasDark: "#000000", inkDark: "#EDEDED"),
              isBuiltIn: true),
        Theme(name: "spatial", title: "Spatial",
              palette: Palette(canvas: "#FFFFFF", ink: "#161819", canvasDark: "#191B1D", inkDark: "#F4F9FA"),
              isBuiltIn: true),
    ]

    static func builtIn(named name: String) -> Theme? {
        builtIn.first { $0.name == name }
    }

    /// The name as stored: trimmed, lowercased, and with the pre-0.2
    /// `spatial-dark` and `apple-dark` spellings mapped to the renamed
    /// themes. Empty for a blank value.
    static func canonicalName(_ text: String) -> String {
        let name = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch name {
        case "spatial-dark": return "spatial"
        case "apple-dark": return "apple"
        default: return name
        }
    }

    /// A user theme parsed from a theme file. Canvas and ink the file leaves
    /// out fall back to Enso's, so a light-only theme still has a dark pair;
    /// the optional tones stay unset and derive from the ink as usual.
    static func user(named name: String, text: String) -> Theme {
        let base = Palette(
            canvas: enso.palette.canvas, ink: enso.palette.ink,
            canvasDark: enso.palette.canvasDark, inkDark: enso.palette.inkDark
        )
        return Theme(
            name: canonicalName(name),
            title: name,
            palette: base.applying(Configuration.parse(text).colorOverrides),
            isBuiltIn: false
        )
    }
}

/// `#RRGGBB` (case-insensitive, `#` optional) to sRGB components and back.
enum HexColor {
    static func components(_ text: String) -> (red: Double, green: Double, blue: Double)? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    static func normalized(_ text: String) -> String? {
        guard let c = components(text) else { return nil }
        return string(red: c.red, green: c.green, blue: c.blue)
    }

    /// `top` laid over `base` at `alpha`, as a hex: the opaque colour a
    /// translucent tone reads as on the canvas, so Settings can show it.
    static func blend(_ top: String, over base: String, alpha: Double) -> String? {
        guard let t = components(top), let b = components(base) else { return nil }
        func mix(_ a: Double, _ c: Double) -> Double { c + (a - c) * alpha }
        return string(red: mix(t.red, b.red), green: mix(t.green, b.green), blue: mix(t.blue, b.blue))
    }

    static func string(red: Double, green: Double, blue: Double) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
