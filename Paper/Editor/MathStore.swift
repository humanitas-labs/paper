import AppKit
import CryptoKit
import SwiftMath

/// Typesets LaTeX with SwiftMath and keeps the results, so the styler can
/// reserve a formula's height and the text view can draw it without
/// typesetting again. SwiftMath's typesetter is internal; its label, laid
/// out offscreen, is the public way to a display list.
@MainActor
final class MathStore {
    static let shared = MathStore()

    enum Style: Hashable {
        /// Centred on its own band, big operators with their limits above
        /// and below.
        case display
        /// On the text's baseline, fractions and limits compact.
        case inline
    }

    /// A typeset formula. The box is `width` by `ascent + descent`, the
    /// baseline `descent` above its bottom edge.
    @MainActor
    final class Formula {
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        /// The offscreen label that typeset the formula: SwiftMath takes
        /// the colour through it.
        private let label: MTMathUILabel
        private let display: MTMathListDisplay

        var height: CGFloat { ascent + descent }

        /// The box at most `width` wide, scaled down evenly when wider.
        func fitted(to width: CGFloat) -> NSSize {
            let scale = width > 0 ? min(1, width / self.width) : 1
            return NSSize(width: self.width * scale, height: height * scale)
        }

        fileprivate init(label: MTMathUILabel, display: MTMathListDisplay, width: CGFloat, ascent: CGFloat, descent: CGFloat) {
            self.label = label
            self.display = display
            self.width = width
            self.ascent = ascent
            self.descent = descent
        }

        /// Draws the formula into `rect` (flipped view coordinates, top
        /// left origin), scaled to the rect's width, in `color`. The colour
        /// is set here, not at typesetting, so a cached formula follows the
        /// drawing appearance: SwiftMath resolves it to a `CGColor` on set.
        func draw(in rect: NSRect, color: NSColor) {
            guard let context = NSGraphicsContext.current?.cgContext, width > 0 else { return }
            let scale = rect.width / width
            label.textColor = color
            context.saveGState()
            // SwiftMath draws y-up with the box's bottom at the origin; its
            // rules stroke through `NSBezierPath`, which draws into this
            // same context, so one transform covers glyphs and rules.
            context.translateBy(x: rect.minX, y: rect.minY + height * scale)
            context.scaleBy(x: scale, y: -scale)
            context.textMatrix = .identity
            display.draw(context)
            context.restoreGState()
        }
    }

    struct Failure: Error, Equatable {
        let message: String
    }

    private struct Key: Hashable {
        let latex: String
        let style: Style
        let size: CGFloat
        let font: MathFont
    }

    /// Enough for every formula in a long document at two sizes; beyond
    /// it the oldest entries go first.
    private let capacity = 1024
    private var entries: [Key: Result<Formula, Failure>] = [:]
    private var order: [Key] = []
    private var fonts: [FontKey: MTFont] = [:]

    private struct FontKey: Hashable {
        let font: MathFont
        let size: CGFloat
    }
    private let fontManager = MTFontManager()

    func typeset(_ latex: String, style: Style, size: CGFloat) -> Result<Formula, Failure> {
        let key = Key(latex: latex, style: style, size: size, font: Appearance.mathFont)
        if let entry = entries[key] { return entry }
        let entry = make(key)
        entries[key] = entry
        order.append(key)
        if order.count > capacity {
            let evicted = order.prefix(order.count - capacity)
            evicted.forEach { entries[$0] = nil }
            order.removeFirst(evicted.count)
        }
        return entry
    }

    private func make(_ key: Key) -> Result<Formula, Failure> {
        let trimmed = key.latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(Failure(message: "Empty formula")) }
        let label = MTMathUILabel()
        label.labelMode = key.style == .display ? .display : .text
        label.textAlignment = .left
        label.contentInsets = NSEdgeInsets()
        label.font = font(key.font, size: key.size)
        label.latex = trimmed
        if let error = label.error {
            return .failure(Failure(message: error.localizedDescription))
        }
        let fitting = label.fittingSize
        guard fitting.width > 0 else { return .failure(Failure(message: "Nothing to draw")) }
        // At least half the font size tall, as the label centres anything
        // shorter; at that height the label puts the baseline exactly
        // `descent` above the bottom, which `draw(in:color:)` relies on.
        label.frame = NSRect(x: 0, y: 0, width: fitting.width, height: max(fitting.height, key.size / 2))
        label.layout()
        guard let display = label.displayList else { return .failure(Failure(message: "Nothing to draw")) }
        let ascent = display.ascent + max(0, key.size / 2 - display.ascent - display.descent)
        return .success(Formula(label: label, display: display, width: display.width, ascent: ascent, descent: display.descent))
    }

    /// The display formula for a block's source at the current size.
    func display(_ latex: String) -> Result<Formula, Failure> {
        typeset(latex, style: .display, size: Appearance.mathSize)
    }

    /// The height of the band under a display block: the formula fitted
    /// to `width` with padding above and below, or one line for the
    /// message when it does not parse. The styler reserves it and the
    /// layout manager measures by it, so both read it from here.
    func bandHeight(for latex: String, width: CGFloat) -> CGFloat {
        switch display(latex) {
        case .success(let formula):
            return formula.fitted(to: width).height + 2 * Appearance.mathBandPadding
        case .failure:
            let font = Appearance.codeFont()
            return ceil(font.ascender - font.descender + font.leading) + Appearance.mathBandPadding
        }
    }

    /// The size a formula is set at for the expanded view; vector, so the
    /// viewer scales it cleanly either way.
    static let previewSize: CGFloat = 48

    /// Where the expanded-view PDFs go. Emptied at every launch, so the
    /// files last one session and a crash leaves nothing behind for long.
    static var previewFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("paper-math", isDirectory: true)
    }

    static func removePreviewFiles() {
        try? FileManager.default.removeItem(at: previewFolder)
    }

    /// A one-page PDF of the display formula, black on white with a margin,
    /// for Quick Look to show enlarged. Written once per source into the
    /// temporary directory and reused; nil when the source does not parse
    /// or the file cannot be written.
    func previewFile(for latex: String) -> URL? {
        let digest = SHA256.hash(data: Data((Appearance.mathFont.rawValue + "\n" + latex).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let folder = Self.previewFolder
        let url = folder.appendingPathComponent("formula-\(digest).pdf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard case .success(let formula) = typeset(latex, style: .display, size: Self.previewSize) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let margin = Self.previewSize
        var page = CGRect(x: 0, y: 0, width: ceil(formula.width + 2 * margin), height: ceil(formula.height + 2 * margin))
        guard let context = CGContext(url as CFURL, mediaBox: &page, nil) else { return nil }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(page)
        // Flipped, as a view draws, so the formula takes the same path.
        context.translateBy(x: 0, y: page.height)
        context.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        formula.draw(
            in: NSRect(x: margin, y: margin, width: formula.width, height: formula.height),
            color: .black
        )
        NSGraphicsContext.current = previous
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private func font(_ face: MathFont, size: CGFloat) -> MTFont? {
        let key = FontKey(font: face, size: size)
        if let font = fonts[key] { return font }
        let font = fontManager.font(withName: face.resourceName, size: size)
        fonts[key] = font
        return font
    }
}
