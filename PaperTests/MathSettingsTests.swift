import AppKit
import Testing
@testable import Paper

/// The math keys: `math` turns typesetting on and off, `math.font` picks
/// one of SwiftMath's faces, `math.scale` sizes it, and `color.math` inks
/// it. Each applies live, through the restyle a configuration change runs.
@MainActor
struct MathSettingsTests {
    private func withConfiguration<T>(_ configure: (inout Configuration) -> Void, _ body: () throws -> T) rethrows -> T {
        let store = ConfigurationStore.shared
        let saved = store.current
        defer { store.apply(saved) }
        var configuration = Configuration()
        configure(&configuration)
        store.apply(configuration)
        return try body()
    }

    private func styledView(_ text: String) -> PaperTextView {
        let textView = PaperTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        textView.string = text
        textView.syntaxStyler.apply(to: textView)
        return textView
    }

    // MARK: Parsing

    @Test
    func mathKeysParseWithDefaultsAndClamps() {
        let defaults = Configuration()
        #expect(defaults.math && defaults.mathFont == .latinModern && defaults.mathScale == 1)

        let parsed = Configuration.parse("""
        math = off
        math.font = Libertinus
        math.scale = 1.5
        color.math = #224488
        color.math.dark = #AABBCC
        """)
        #expect(!parsed.math)
        #expect(parsed.mathFont == .libertinus)
        #expect(parsed.mathScale == 1.5)
        #expect(parsed.mathColor == "#224488")
        #expect(parsed.mathColorDark == "#AABBCC")

        #expect(Configuration.parse("math.font = Latin Modern").mathFont == .latinModern)
        #expect(Configuration.parse("math.font = kpmath_sans").mathFont == .kpMathSans)
        #expect(Configuration.parse("math.font = comic sans").mathFont == .latinModern, "unknown keeps the default")
        #expect(Configuration.parse("math.scale = 9").mathScale == 2)
        #expect(Configuration.parse("math.scale = 0.1").mathScale == 0.5)
    }

    @Test
    func mathKeysRoundTripThroughTheFile() {
        var configuration = Configuration()
        configuration.math = false
        configuration.mathFont = .fira
        configuration.mathScale = 1.25
        configuration.mathColor = "#112233"
        #expect(Configuration.parse(configuration.merged(into: Configuration.template)) == configuration)
    }

    @Test
    func everyFontLoads() {
        for font in MathFont.allCases {
            withConfiguration({ $0.mathFont = font }) {
                guard case .success(let formula) = MathStore.shared.display("\\frac{a}{b} + \\sqrt{x}") else {
                    Issue.record("\(font.title) did not typeset")
                    return
                }
                #expect(formula.width > 0, "\(font.title)")
            }
        }
    }

    // MARK: Rendering

    @Test
    func mathOffLeavesTheSourceAsTyped() throws {
        try withConfiguration({ $0.math = false }) {
            let textView = styledView("A $x^2$ line.\n\n$$\n\\frac{a}{b}\n$$\n\n```math\ny\n```\n")
            let storage = try #require(textView.textStorage)
            let text = textView.string as NSString
            var marked = false
            for key in [NSAttributedString.Key.mathSource, .inlineMath, .reservedWidth] {
                storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                    if value != nil { marked = true }
                }
            }
            #expect(!marked, "nothing is math")
            #expect(storage.attribute(.concealable, at: text.range(of: "x^2").location, effectiveRange: nil) == nil)
            #expect(storage.attribute(.codeBlock, at: text.range(of: "y\n```").location, effectiveRange: nil) != nil, "a math fence is code")
        }
    }

    @Test
    func theFontChangesTheFormula() {
        func width(_ font: MathFont) -> CGFloat? {
            withConfiguration({ $0.mathFont = font }) {
                guard case .success(let formula) = MathStore.shared.display("\\sum_{i=1}^{n} x_i = y") else { return nil }
                return formula.width
            }
        }
        #expect(width(.latinModern) != nil)
        #expect(width(.latinModern) != width(.notoSans))
    }

    @Test
    func theScaleSizesDisplayAndInlineMath() {
        let body = Appearance.bodyFont()
        let base = withConfiguration({ _ in }) { (display: Appearance.mathSize, inline: Appearance.inlineMathSize(for: body)) }
        withConfiguration({ $0.mathScale = 1.5 }) {
            #expect(abs(Appearance.mathSize - base.display * 1.5) < 0.001)
            #expect(abs(Appearance.inlineMathSize(for: body) - base.inline * 1.5) < 0.001)
        }
    }

    @Test
    func aFaceWithATallerXHeightSetsInlineMathSmaller() {
        let body = Appearance.bodyFont()
        let latin = withConfiguration({ $0.mathFont = .latinModern }) { Appearance.inlineMathSize(for: body) }
        let noto = withConfiguration({ $0.mathFont = .notoSans }) { Appearance.inlineMathSize(for: body) }
        #expect(noto <= latin)
        #expect(noto >= body.pointSize, "never smaller than the text")
    }

    @Test
    func theMathInkColoursFormulas() throws {
        try withConfiguration({ $0.mathColor = "#CC2200" }) {
            let textView = styledView("A $x$ line.\n")
            let math = try #require(textView.textStorage?.attribute(.inlineMath, at: 2, effectiveRange: nil) as? InlineMath)
            let ink = try #require(math.color.usingColorSpace(.sRGB))
            #expect(abs(ink.redComponent - 0.8) < 0.01 && ink.blueComponent < 0.01)
        }
        let textView = styledView("A $x$ line.\n")
        let math = try #require(textView.textStorage?.attribute(.inlineMath, at: 2, effectiveRange: nil) as? InlineMath)
        #expect(math.color == Appearance.mathInk, "unset, math is in the math ink")
        #expect(math.color.usingColorSpace(.sRGB) == Appearance.ink.usingColorSpace(.sRGB), "which is the ink")
    }

    @Test
    func thePreviewFollowsTheFont() throws {
        let latex = "\\int_0^1 x\\,dx"
        let latin = try #require(withConfiguration({ $0.mathFont = .latinModern }) { MathStore.shared.previewFile(for: latex) })
        let fira = try #require(withConfiguration({ $0.mathFont = .fira }) { MathStore.shared.previewFile(for: latex) })
        #expect(latin != fira)
    }
}
