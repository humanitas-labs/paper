import AppKit

extension NSAttributedString.Key {
    /// Marks block-quote paragraphs so the text view can draw their rule.
    static let blockQuote = NSAttributedString.Key("paper.blockQuote")

    /// Marks fenced-code-block paragraphs (fences included) so the text
    /// view can draw their background band.
    static let codeBlock = NSAttributedString.Key("paper.codeBlock")

    /// Marks Markdown punctuation that is hidden whenever the selection is
    /// not on its paragraph. A pure annotation: the characters stay in
    /// storage and in the saved file.
    static let concealable = NSAttributedString.Key("paper.concealable")

    /// Marks a character drawn as another glyph off the active paragraph:
    /// the value is the single character to draw in its place (`–` for a `-`
    /// list marker, `•` for `*` and `+`, `→` for the `>` of `->`). The
    /// source character is untouched.
    static let glyphSubstitute = NSAttributedString.Key("paper.glyphSubstitute")
    static let thematicBreak = NSAttributedString.Key("paper.thematicBreak")
    /// The destination of a Markdown link, as its source string, on the
    /// link's text. Opened with ⌘-click; a plain click places the caret.
    static let linkDestination = NSAttributedString.Key("paper.linkDestination")
    /// The `(destination)` of a link or image: a path or URL, not prose,
    /// so text checking leaves it alone.
    static let address = NSAttributedString.Key("paper.address")
    /// Marks a paragraph that is a block image (`![alt](file)` alone on its
    /// line) whose file loaded; the value is the resolved file `URL`. The
    /// paragraph's spacing reserves the band the text view draws it in.
    static let imageSource = NSAttributedString.Key("paper.imageSource")
    /// Marks a task item's prefix, from its list marker through the `]` of
    /// its `[ ]` / `[x]` box. The run conceals on every paragraph, the
    /// active one included, and the text view draws a circle in its place;
    /// a click on the circle flips the character between the brackets.
    static let taskBox = NSAttributedString.Key("paper.taskBox")
    /// Marks a plain list item's marker (`-`, `*`, `+`, `1.`). Its glyph
    /// substitute holds on the active paragraph too, so an item never
    /// reflows when the caret enters it (#50).
    static let listMarker = NSAttributedString.Key("paper.listMarker")
    /// Marks concealable source that stays concealed on the active
    /// paragraph too: the indent a hard-wrapped list item's continuation
    /// carries, which nobody edits by hand and whose reveal would shift
    /// the line sideways under the caret with nothing new to see.
    static let pinned = NSAttributedString.Key("paper.pinned")
    /// Marks a character that, while concealed, draws nothing and takes the
    /// width the value (a `CGFloat`) names: room for something the text view
    /// draws itself, like a task item's circle.
    static let reservedWidth = NSAttributedString.Key("paper.reservedWidth")
    /// Marks the paragraphs of a display-math block (`$$ … $$` or a `math`
    /// fence), delimiters included; the value is its `MathBlock`. The last
    /// line's spacing reserves the band the text view draws the formula in.
    static let mathSource = NSAttributedString.Key("paper.mathSource")
    /// Marks an inline formula's source, `$` to `$`; the value is its
    /// `InlineMath`. Off the active paragraph the first `$` reserves the
    /// formula's width and the text view draws the formula there.
    static let inlineMath = NSAttributedString.Key("paper.inlineMath")
}

/// The LaTeX of one display-math block. Equal by source, so a restyle
/// that sets the same block again leaves the storage equal to a full pass;
/// the price is that two identical blocks on consecutive lines read as one.
final class MathBlock: NSObject {
    let latex: String

    init(latex: String) {
        self.latex = latex
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? MathBlock)?.latex == latex
    }

    override var hash: Int { latex.hashValue }
}

/// One inline formula: its LaTeX, the size it sets at (matched to the
/// surrounding text), and the ink it draws in. Equal by value, like
/// `MathBlock`, so an incremental restyle compares equal to a full pass.
final class InlineMath: NSObject {
    let latex: String
    let size: CGFloat
    let color: NSColor

    init(latex: String, size: CGFloat, color: NSColor) {
        self.latex = latex
        self.size = size
        self.color = color
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? InlineMath else { return false }
        return other.latex == latex && other.size == size && other.color == color
    }

    override var hash: Int { latex.hashValue ^ size.hashValue }
}

/// TextKit 1 layout manager that computes margin decorations and conceals
/// marked punctuation. It does not draw decorations: `NSTextView` clips
/// layout-manager drawing to the text container, and the block-quote rule
/// sits in the margin outside it, so `PaperTextView` draws the rects this
/// returns.
///
/// Concealment is a glyph-generation decision. Every `.concealable`
/// character outside `activeRange` gets a `.null` glyph property, which lays
/// out with zero advance and draws nothing. Storage, undo, find, and copy
/// never see the difference.
final class PaperLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    /// Characters whose punctuation is shown: the paragraphs touched by the
    /// selection. Empty until the text view sets it.
    private(set) var activeRange = NSRange(location: 0, length: 0)

    override init() {
        super.init()
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    // MARK: Spelling marks

    // The checker lays its underlines down as the `.spellingState`
    // temporary attribute, and on current macOS it does so through the
    // layout manager directly rather than the text view's result handler.
    // So the mark is refused here, at the one choke point every path
    // shares, wherever the storage says the characters are code.

    override func addTemporaryAttribute(_ attrName: NSAttributedString.Key, value: Any, forCharacterRange charRange: NSRange) {
        guard attrName == .spellingState else {
            return super.addTemporaryAttribute(attrName, value: value, forCharacterRange: charRange)
        }
        for range in proseRanges(in: charRange, mark: value) {
            super.addTemporaryAttribute(attrName, value: value, forCharacterRange: range)
        }
    }

    override func addTemporaryAttributes(_ attrs: [NSAttributedString.Key: Any], forCharacterRange charRange: NSRange) {
        guard let mark = attrs[.spellingState] else {
            return super.addTemporaryAttributes(attrs, forCharacterRange: charRange)
        }
        var rest = attrs
        rest[.spellingState] = nil
        if !rest.isEmpty { super.addTemporaryAttributes(rest, forCharacterRange: charRange) }
        for range in proseRanges(in: charRange, mark: mark) {
            super.addTemporaryAttribute(.spellingState, value: mark, forCharacterRange: range)
        }
    }

    override func setTemporaryAttributes(_ attrs: [NSAttributedString.Key: Any], forCharacterRange charRange: NSRange) {
        guard let mark = attrs[.spellingState] else {
            return super.setTemporaryAttributes(attrs, forCharacterRange: charRange)
        }
        var rest = attrs
        rest[.spellingState] = nil
        super.setTemporaryAttributes(rest, forCharacterRange: charRange)
        for range in proseRanges(in: charRange, mark: mark) {
            super.addTemporaryAttribute(.spellingState, value: mark, forCharacterRange: range)
        }
    }

    /// The parts of `charRange` that are not code: not a fenced block, not
    /// an inline span, not a link or image address. A spelling mark (not a
    /// grammar one) on a token that is not a word is dropped whole.
    private func proseRanges(in charRange: NSRange, mark: Any) -> [NSRange] {
        guard let storage = textStorage else { return [charRange] }
        let clipped = NSIntersectionRange(charRange, NSRange(location: 0, length: storage.length))
        guard clipped.length > 0 else { return [] }
        let isSpelling = (mark as? NSNumber)?.intValue == NSAttributedString.SpellingState.spelling.rawValue
        if isSpelling, !SpellCheckFilter.keepsMark(at: clipped, in: storage.string as NSString) { return [] }
        var ranges: [NSRange] = []
        storage.enumerateAttributes(in: clipped) { attributes, range, _ in
            guard !PaperTextView.isCode(attributes) else { return }
            if let last = ranges.last, NSMaxRange(last) == range.location {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }

    /// Changes the revealed range, regenerating glyphs only for the parts of
    /// the old and new ranges that carry concealable punctuation or list
    /// markers. Paragraphs without either cost nothing to enter or leave.
    func setActiveRange(_ range: NSRange) {
        let previous = activeRange
        guard range != previous else { return }
        activeRange = range

        for stale in [previous, range] {
            guard let clipped = clip(stale), containsRenderMarks(clipped) else { continue }
            invalidateGlyphs(forCharacterRange: clipped, changeInLength: 0, actualCharacterRange: nil)
            // Layout must be invalidated through to the end: with contiguous
            // layout, re-laying only the paragraph leaves the fragments after
            // it stale and double-counts its paragraph spacing.
            let toEnd = NSRange(location: clipped.location, length: (textStorage?.length ?? 0) - clipped.location)
            invalidateLayout(forCharacterRange: toEnd, actualCharacterRange: nil)
            invalidateDisplay(forCharacterRange: toEnd)
        }
    }

    /// Whether the character is concealed under the current active range.
    /// A task prefix (`.taskBox`) conceals on the active paragraph too: the
    /// circle stays and the caret never enters it (#53).
    func isConcealed(characterAt index: Int) -> Bool {
        guard let storage = textStorage, index < storage.length else { return false }
        let attributes = storage.attributes(at: index, effectiveRange: nil)
        guard attributes[.concealable] != nil else { return false }
        return !NSLocationInRange(index, activeRange) || Self.isPinned(attributes)
    }

    /// Whether the run's rendering holds on the active paragraph: a task
    /// prefix, a list marker, or source marked `.pinned`.
    static func isPinned(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        attributes[.taskBox] != nil || attributes[.listMarker] != nil || attributes[.pinned] != nil
    }

    private func clip(_ range: NSRange) -> NSRange? {
        guard let storage = textStorage else { return nil }
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        return clipped.length > 0 ? clipped : nil
    }

    private func containsRenderMarks(_ range: NSRange) -> Bool {
        guard let storage = textStorage else { return false }
        var found = false
        storage.enumerateAttributes(in: range) { attributes, _, stop in
            if attributes[.concealable] != nil || attributes[.glyphSubstitute] != nil || attributes[.reservedWidth] != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: - NSLayoutManagerDelegate

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let storage = textStorage, glyphRange.length > 0 else { return 0 }

        // Most batches lie inside one unmarked attribute run; leave those to
        // the default generation without touching every glyph.
        var runRange = NSRange(location: NSNotFound, length: 0)
        var run = markers(at: characterIndexes[0], in: storage, effectiveRange: &runRange)
        if run.isEmpty, NSMaxRange(runRange) > characterIndexes[glyphRange.length - 1] {
            return 0
        }

        var replacedProperties: [NSLayoutManager.GlyphProperty]?
        var replacedGlyphs: [CGGlyph]?
        for offset in 0..<glyphRange.length {
            let index = characterIndexes[offset]
            if !NSLocationInRange(index, runRange) {
                // One lookup per attribute run. `effectiveRange` (not the
                // longest) matters: merging unmarked runs would scan the
                // document to the next heading for every batch of glyphs.
                run = markers(at: index, in: storage, effectiveRange: &runRange)
            }
            guard !run.isEmpty, !NSLocationInRange(index, activeRange) || run.pinned else { continue }

            if run.concealable || run.reservedWidth != nil {
                if replacedProperties == nil {
                    replacedProperties = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
                }
                // Control glyphs with zero advancement, not `.null`: a null
                // glyph at a paragraph's start attaches to the previous
                // line's fragment, and that fragment then drops its
                // paragraph spacing — the layout jumped when a heading's
                // concealed marker followed an empty line. A control glyph
                // stays in its own fragment, draws nothing, and takes no
                // width (the zero advancement comes from the control-action
                // delegate below).
                replacedProperties?[offset] = .controlCharacter
            } else if let rendered = run.substitute, let glyph = Self.glyph(for: rendered, in: font) {
                if replacedGlyphs == nil {
                    replacedGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
                }
                replacedGlyphs?[offset] = glyph
            }
        }

        guard replacedProperties != nil || replacedGlyphs != nil else { return 0 }
        let finalProperties = replacedProperties ?? Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        let finalGlyphs = replacedGlyphs ?? Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        finalProperties.withUnsafeBufferPointer { propertyBuffer in
            finalGlyphs.withUnsafeBufferPointer { glyphBuffer in
                layoutManager.setGlyphs(
                    glyphBuffer.baseAddress!,
                    properties: propertyBuffer.baseAddress!,
                    characterIndexes: characterIndexes,
                    font: font,
                    forGlyphRange: glyphRange
                )
            }
        }
        return glyphRange.length
    }

    /// Concealed characters were generated as control glyphs; they take no
    /// space. One with a reserved width takes that width as whitespace (see
    /// the bounding-box delegate below). Real control characters (tabs,
    /// line breaks) keep their action.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = textStorage, charIndex < storage.length else { return action }
        let attributes = storage.attributes(at: charIndex, effectiveRange: nil)
        guard !NSLocationInRange(charIndex, activeRange) || Self.isPinned(attributes) else { return action }
        if attributes[.reservedWidth] != nil { return .whitespace }
        guard attributes[.concealable] != nil else { return action }
        let character = (storage.string as NSString).character(at: charIndex)
        guard character != 0x0A, character != 0x0D, character != 0x09 else { return action }
        return .zeroAdvancement
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        boundingBoxForControlGlyphAt glyphIndex: Int,
        for textContainer: NSTextContainer,
        proposedLineFragment proposedRect: NSRect,
        glyphPosition: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        guard let storage = textStorage, charIndex < storage.length,
              let width = storage.attribute(.reservedWidth, at: charIndex, effectiveRange: nil) as? CGFloat
        else { return NSRect(origin: glyphPosition, size: NSSize(width: 0, height: proposedRect.height)) }
        return NSRect(x: glyphPosition.x, y: glyphPosition.y, width: width, height: proposedRect.height)
    }

    /// The used rect's bottom after the previous complete layout, for the
    /// vacated-area invalidation below.
    private var lastUsedBottom: CGFloat = 0

    /// Every display invalidation in TextKit is character-based, so when an
    /// edit shortens the layout, the strip the text vacated below the new
    /// bottom holds no characters and is never repainted — the old last line
    /// survives there as stale pixels (a deleted newline appeared to leave
    /// its paragraph duplicated). When a completed layout ends higher than
    /// the previous one, redraw the strip between the two bottoms.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        didCompleteLayoutFor textContainer: NSTextContainer?,
        atEnd layoutFinishedFlag: Bool
    ) {
        guard layoutFinishedFlag else { return }
        // Layout always completes on the main thread; the unsafe capture is
        // the region checker's price for hopping into the actor to reach the
        // text view.
        nonisolated(unsafe) let manager = self
        MainActor.assumeIsolated {
            guard let container = manager.textContainers.first else { return }
            let bottom = manager.usedRect(for: container).maxY
            let stale = manager.lastUsedBottom
            manager.lastUsedBottom = bottom
            guard bottom < stale, let textView = container.textView else { return }
            let origin = textView.textContainerOrigin
            textView.setNeedsDisplay(NSRect(
                x: 0,
                y: origin.y + bottom,
                width: textView.bounds.width,
                height: stale - bottom
            ))
        }
    }

    /// The rendering marks on the attribute run at `index`.
    private struct Marks {
        var concealable = false
        var substitute: Character?
        var reservedWidth: CGFloat?
        /// A task prefix or list marker: rendered on the active paragraph
        /// as well.
        var pinned = false
        var isEmpty: Bool { !concealable && substitute == nil && reservedWidth == nil }
    }

    private func markers(at index: Int, in storage: NSTextStorage, effectiveRange: NSRangePointer) -> Marks {
        let attributes = storage.attributes(at: index, effectiveRange: effectiveRange)
        var marks = Marks()
        marks.concealable = attributes[.concealable] != nil
        marks.substitute = (attributes[.glyphSubstitute] as? String)?.first
        marks.reservedWidth = attributes[.reservedWidth] as? CGFloat
        marks.pinned = Self.isPinned(attributes)
        return marks
    }

    /// The font's glyph for a single character, or nil when the font lacks
    /// it (the source character is drawn instead).
    static func glyph(for character: Character, in font: NSFont) -> CGGlyph? {
        let units = Array(String(character).utf16)
        guard units.count == 1 else { return nil }
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, units, &glyph, 1), glyph != 0 else { return nil }
        return glyph
    }

    /// The origin `drawBackground(forGlyphRange:at:)` was last given, so the
    /// chip drawing below can place container-coordinate rects itself; the
    /// rects TextKit passes to `fillBackgroundRectArray` are already offset.
    private var backgroundDrawOrigin = NSPoint.zero

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        backgroundDrawOrigin = origin
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// Chip rects (in text-container coordinates) for an inline code span:
    /// one per line fragment the span touches, clamped to the glyphs it holds
    /// there. TextKit's own background rects are selection-shaped — a wrapped
    /// run extends the first line to the fragment's trailing edge and starts
    /// the next at its leading edge — which warps a chip meant to hug text.
    func codeChipRects(forCharacterRange charRange: NSRange) -> [NSRect] {
        let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var rects: [NSRect] = []
        enumerateLineFragments(forGlyphRange: glyphs) { _, _, container, fragmentGlyphs, _ in
            let intersection = NSIntersectionRange(fragmentGlyphs, glyphs)
            guard intersection.length > 0 else { return }
            let rect = self.boundingRect(forGlyphRange: intersection, in: container)
            // A fragment holding only concealed (zero-advance) span glyphs
            // has nothing to chip.
            guard rect.width > 0.5 else { return }
            rects.append(rect)
        }
        return rects
    }

    /// Inline `code` spans carry the band colour as a background attribute;
    /// those fills are drawn as rounded chips hugging the glyph box instead
    /// of full-height rectangles. Every other background (selection included)
    /// keeps the default drawing.
    override func fillBackgroundRectArray(
        _ rectArray: UnsafePointer<NSRect>,
        count rectCount: Int,
        forCharacterRange charRange: NSRange,
        color: NSColor
    ) {
        let chip: (height: CGFloat, radius: CGFloat)? = MainActor.assumeIsolated {
            guard color == Appearance.codeBlockBackground else { return nil }
            // The line-height leading sits above the glyphs, so the chip
            // anchors to the fragment's bottom edge, like the caret.
            let font = Appearance.codeFont()
            return (font.ascender - font.descender + 4, Appearance.codeChipCornerRadius)
        }
        guard let chip else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        let height = chip.height
        let origin = backgroundDrawOrigin
        color.setFill()
        for rect in codeChipRects(forCharacterRange: charRange) {
            let placed = rect.offsetBy(dx: origin.x, dy: origin.y)
            NSBezierPath(
                roundedRect: NSRect(
                    x: placed.minX - 2,
                    y: placed.maxY - min(height, placed.height),
                    width: placed.width + 4,
                    height: min(height, placed.height)
                ),
                xRadius: chip.radius,
                yRadius: chip.radius
            ).fill()
        }
    }

    // MARK: - Margin decorations

    private func hasVisibleGlyphs(in range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        for index in range.location..<NSMaxRange(range) {
            switch propertyForGlyph(at: index) {
            case .null, .controlCharacter: continue
            default: return true
            }
        }
        return false
    }

    /// Rects (in text-container coordinates) covering each fenced code
    /// block that intersects `glyphRange`. Fence lines count: concealed off
    /// the active paragraph, they read as the band's vertical padding.
    @MainActor
    func codeBlockRects(forGlyphRange glyphRange: NSRange) -> [NSRect] {
        codeBlocks(forGlyphRange: glyphRange).map(\.rect)
    }

    /// The bands with the paragraph range (fences included) of the block
    /// each one covers, in document order.
    func codeBlocks(forGlyphRange glyphRange: NSRange) -> [(range: NSRange, rect: NSRect)] {
        guard let storage = textStorage else { return [] }
        let characterRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        var rects: [(range: NSRange, rect: NSRect)] = []
        var measured: [NSRange] = []
        storage.enumerateAttribute(.codeBlock, in: characterRange) { value, partial, _ in
            guard value != nil else { return }
            // As with the quote rule, measure the whole block even when the
            // dirty rect covers one line of it, or partial redraws leave
            // unpainted strips; drawing is clipped to the dirty rect anyway.
            var range = NSRange()
            _ = storage.attribute(.codeBlock, at: partial.location, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length))
            guard !measured.contains(range) else { return }
            measured.append(range)
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var top = CGFloat.greatestFiniteMagnitude
            var bottom = -CGFloat.greatestFiniteMagnitude
            enumerateLineFragments(forGlyphRange: glyphs) { fragment, used, _, fragmentGlyphs, _ in
                // A fragment that merely carries attached zero-width glyphs
                // from the block starts outside it; counting it would grow
                // the band over the line above.
                let first = self.characterIndexForGlyph(at: fragmentGlyphs.location)
                guard NSLocationInRange(first, range) else { return }
                top = min(top, fragment.minY)
                // The used rect's bottom excludes the closing fence's
                // paragraph spacing, so the band hugs its last row.
                bottom = max(bottom, used.maxY)
            }
            guard bottom > top else { return }
            rects.append((range, NSRect(x: 0, y: top, width: 0, height: bottom - top)))
        }
        return rects
    }

    /// The band (in text-container coordinates) under each block-image
    /// paragraph intersecting `glyphRange`, with the image file it shows.
    /// The band is the paragraph's spacing: it starts under the line's used
    /// rect and is as tall as the image fits into `width`, so the source
    /// line above stays put whether it is concealed or revealed.
    @MainActor
    func imageBands(forGlyphRange glyphRange: NSRange, width: CGFloat) -> [(rect: NSRect, url: URL)] {
        guard let storage = textStorage else { return [] }
        let characterRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var bands: [(rect: NSRect, url: URL)] = []
        var measured: [NSRange] = []
        storage.enumerateAttribute(.imageSource, in: characterRange) { value, partial, _ in
            guard let url = value as? URL else { return }
            var range = NSRange()
            _ = storage.attribute(
                .imageSource, at: partial.location,
                longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)
            )
            guard !measured.contains(range) else { return }
            measured.append(range)
            guard let dimensions = ImageStore.shared.dimensions(for: url) else { return }
            let size = ImageStore.fit(dimensions.naturalSize, width: width)
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var bottom = -CGFloat.greatestFiniteMagnitude
            var padding: CGFloat = 0
            enumerateLineFragments(forGlyphRange: glyphs) { _, used, container, fragmentGlyphs, _ in
                let first = self.characterIndexForGlyph(at: fragmentGlyphs.location)
                guard NSLocationInRange(first, range) else { return }
                bottom = max(bottom, used.maxY)
                // The concealed line's used rect starts at 0, not at the
                // padding the text stands on; the band takes the text's edge.
                padding = container.lineFragmentPadding
            }
            guard bottom > -CGFloat.greatestFiniteMagnitude else { return }
            bands.append((NSRect(x: padding, y: bottom, width: size.width, height: size.height), url))
        }
        return bands
    }

    /// Each display-math block intersecting `glyphRange`, in text-container
    /// coordinates: `block` spans its source rows and its band, `band` the
    /// band alone, under the closing row's used rect, as tall as
    /// `MathStore` says the styler reserved. `active` is whether the caret
    /// has revealed the block's source.
    @MainActor
    func mathBands(
        forGlyphRange glyphRange: NSRange, width: CGFloat
    ) -> [(block: NSRect, band: NSRect, latex: String, active: Bool)] {
        guard let storage = textStorage else { return [] }
        let characterRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var bands: [(block: NSRect, band: NSRect, latex: String, active: Bool)] = []
        var measured: [NSRange] = []
        storage.enumerateAttribute(.mathSource, in: characterRange) { value, partial, _ in
            guard let math = value as? MathBlock else { return }
            var range = NSRange()
            _ = storage.attribute(
                .mathSource, at: partial.location,
                longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)
            )
            guard !measured.contains(range) else { return }
            measured.append(range)
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var top = CGFloat.greatestFiniteMagnitude
            var bottom = -CGFloat.greatestFiniteMagnitude
            var padding: CGFloat = 0
            enumerateLineFragments(forGlyphRange: glyphs) { fragment, used, container, fragmentGlyphs, _ in
                let first = self.characterIndexForGlyph(at: fragmentGlyphs.location)
                guard NSLocationInRange(first, range) else { return }
                top = min(top, fragment.minY)
                bottom = max(bottom, used.maxY)
                padding = container.lineFragmentPadding
            }
            guard bottom > top else { return }
            let height = MathStore.shared.bandHeight(for: math.latex, width: width)
            let band = NSRect(x: padding, y: bottom, width: width, height: height)
            let block = NSRect(x: padding, y: top, width: width, height: band.maxY - top)
            let active = NSIntersectionRange(range, activeRange).length > 0
                || (activeRange.length == 0 && NSLocationInRange(activeRange.location, range))
            bands.append((block, band, math.latex, active))
        }
        return bands
    }

    /// Each concealed inline formula intersecting `glyphRange`, in
    /// text-container coordinates: the rect its first `$` reserves, as wide
    /// as the formula, with the formula's baseline on the line's. A span
    /// the caret has revealed shows its source and yields nothing.
    @MainActor
    func inlineFormulas(forGlyphRange glyphRange: NSRange) -> [(rect: NSRect, math: InlineMath)] {
        guard let storage = textStorage else { return [] }
        let characterRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var formulas: [(rect: NSRect, math: InlineMath)] = []
        var measured: [NSRange] = []
        storage.enumerateAttribute(.inlineMath, in: characterRange) { value, partial, _ in
            guard let math = value as? InlineMath else { return }
            var span = NSRange()
            _ = storage.attribute(
                .inlineMath, at: partial.location,
                longestEffectiveRange: &span, in: NSRange(location: 0, length: storage.length)
            )
            guard !measured.contains(span) else { return }
            measured.append(span)
            guard let width = storage.attribute(.reservedWidth, at: span.location, effectiveRange: nil) as? CGFloat,
                  self.isConcealed(characterAt: span.location),
                  case .success(let formula) = MathStore.shared.typeset(math.latex, style: .inline, size: math.size)
            else { return }
            let glyph = self.glyphIndexForCharacter(at: span.location)
            let fragment = self.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = self.location(forGlyphAt: glyph)
            let scale = formula.width > 0 ? width / formula.width : 1
            formulas.append((NSRect(
                x: fragment.minX + location.x,
                y: fragment.minY + location.y - formula.ascent * scale,
                width: width,
                height: formula.height * scale
            ), math))
        }
        return formulas
    }

    /// Line-fragment rects (in text-container coordinates) of each concealed
    /// thematic break intersecting `glyphRange`. The active paragraph shows
    /// its source instead, so it yields no rect.
    @MainActor
    func thematicBreakRects(forGlyphRange glyphRange: NSRange) -> [NSRect] {
        guard let storage = textStorage else { return [] }
        let characterRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var rects: [NSRect] = []
        var measured: [NSRange] = []
        storage.enumerateAttribute(.thematicBreak, in: characterRange) { value, partial, _ in
            guard value != nil else { return }
            var range = NSRange()
            _ = storage.attribute(
                .thematicBreak, at: partial.location,
                longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)
            )
            guard !measured.contains(range) else { return }
            measured.append(range)
            guard NSIntersectionRange(range, self.activeRange).length == 0 else { return }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            rects.append(self.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil))
        }
        return rects
    }

    /// Rects (in text-container coordinates) covering each contiguous run of
    /// block-quote lines that intersects `glyphRange`.
    @MainActor
    func quoteRuleRects(forGlyphRange glyphRange: NSRange) -> [NSRect] {
        guard let storage = textStorage else { return [] }
        let characterRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        var rects: [NSRect] = []
        var measured: [NSRange] = []
        storage.enumerateAttribute(.blockQuote, in: characterRange) { value, partial, _ in
            guard value != nil else { return }
            // Measure the whole quote run even when the dirty rect covers
            // one line of it: the rect is a union of glyph boxes, and a
            // single fragment's box leaves its leading strip unpainted (a
            // slit in the rule) until a full redraw. Drawing is clipped to
            // the dirty rect regardless.
            var range = NSRange()
            _ = storage.attribute(.blockQuote, at: partial.location, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length))
            guard !measured.contains(range) else { return }
            measured.append(range)
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            // The line-height leading sits above the glyphs in each fragment,
            // so measure from the glyph box (ascent + descent at the
            // fragment's bottom), as the caret does, or the rule starts a
            // leading's height above the first line.
            let font = Appearance.italicFont()
            let glyphBox = font.ascender - font.descender
            var union = NSRect.null
            enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, fragmentGlyphs, _ in
                // Concealed markers are zero-width glyphs that TextKit can
                // attach to the end of the previous fragment (the blank
                // line above); a fragment counts only if it shows something.
                guard self.hasVisibleGlyphs(in: NSIntersectionRange(fragmentGlyphs, glyphs)) else { return }
                let height = min(usedRect.height, glyphBox)
                union = union.union(NSRect(x: usedRect.minX, y: usedRect.maxY - height, width: usedRect.width, height: height))
            }
            guard !union.isNull else { return }
            if let last = rects.last, abs(last.maxY - union.minY) <= Appearance.paragraphSpacing + 1 {
                rects[rects.count - 1] = last.union(union)
            } else {
                rects.append(union)
            }
        }
        return rects
    }
}
