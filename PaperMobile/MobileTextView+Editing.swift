import UIKit

// Editing on the iOS page, after `PaperTextView` on the Mac. The rules
// themselves (list continuation, list prefixes as one unit, typed
// substitutions, task boxes) live in the shared helpers; this file wires
// them to UIKit's text input.

extension MobileTextView: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        onTextChange?(text)
        // Restyling replaces attributes, which would discard an input
        // method's marked text; the commit fires a final change.
        guard markedTextRange == nil else { return }
        syntaxStyler.applyEdited(to: self)
        decorationsNeedDisplay()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard markedTextRange == nil, !adjustingSelection else { return }
        let range = selectedRange
        let text = textStorage.string as NSString
        if NSMaxRange(range) <= text.length {
            // A list item's prefix is one unit for the caret.
            var snapped = ListPrefix.snapped(range, previous: previousSelection, in: text)
            snapped = ContinuationIndent.snapped(snapped, previous: previousSelection, in: textStorage)
            if snapped != range {
                adjustingSelection = true
                selectedRange = snapped
                adjustingSelection = false
            }
        }
        previousSelection = selectedRange
        revealSelectedParagraphs()
    }
}

extension MobileTextView {
    // MARK: - Reveal

    /// The paragraphs the selection touches show their syntax; a display
    /// math block reveals whole. Nothing is revealed while the page is
    /// only being read.
    func revealSelectedParagraphs() {
        guard isFirstResponder else {
            paperLayoutManager.setActiveRange(NSRange(location: 0, length: 0))
            decorationsNeedDisplay()
            return
        }
        let storage = textStorage
        let text = storage.string as NSString
        var paragraph = text.paragraphRange(for: selectedRange.clamped(to: text.length))
        for edge in [paragraph.location, NSMaxRange(paragraph) - 1] where edge >= 0 && edge < storage.length {
            var block = NSRange()
            if storage.attribute(.mathSource, at: edge, longestEffectiveRange: &block,
                                 in: NSRange(location: 0, length: storage.length)) != nil {
                paragraph = NSUnionRange(paragraph, block)
            }
        }
        paperLayoutManager.setActiveRange(paragraph)
        decorationsNeedDisplay()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { revealSelectedParagraphs() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { revealSelectedParagraphs() }
        return resigned
    }

    // MARK: - Typing

    /// Return continues a list or ends it; typed `->`, `--` and `[]` become
    /// Paper's substitutions on the next turn of the run loop, so each is
    /// its own undo step.
    override func insertText(_ typed: String) {
        if typed == "\n", markedTextRange == nil,
           let edit = ListContinuation.edit(in: textStorage.string as NSString, selection: selectedRange) {
            replace(edit.range, with: edit.replacement, selecting: edit.selection)
            return
        }
        super.insertText(typed)
        guard typed.utf16.count == 1, markedTextRange == nil else { return }
        let isDashTrigger = typed == " " || typed.rangeOfCharacter(from: .alphanumerics) != nil
        guard typed == ">" || typed == "]" || isDashTrigger else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.replaceTypedArrow()
            self.replaceTypedDashes()
            self.replaceTypedTaskBox()
        }
    }

    /// Backspace at the start of an item's text removes the whole prefix;
    /// at the start of a continuation line it joins the lines.
    override func deleteBackward() {
        if markedTextRange == nil,
           let unit = ListPrefix.backspaceRange(in: textStorage.string as NSString, selection: selectedRange)
            ?? ContinuationIndent.backspaceRange(in: textStorage, selection: selectedRange) {
            replace(unit, with: "", selecting: NSRange(location: unit.location, length: 0))
            return
        }
        super.deleteBackward()
    }

    /// Tab in a list item indents it a level; Shift-Tab outdents.
    @discardableResult
    func indentListItem(outdent: Bool) -> Bool {
        guard markedTextRange == nil,
              let edit = ListContinuation.indent(in: textStorage.string as NSString, selection: selectedRange, outdent: outdent)
        else { return false }
        replace(edit.range, with: edit.replacement, selecting: edit.selection)
        return true
    }

    /// Applies `format` to the selection, as the Mac's Format menu does.
    func toggle(_ format: InlineFormat) {
        guard markedTextRange == nil else { return }
        let edit = format.toggle(in: textStorage.string as NSString, selection: selectedRange)
        replace(edit.range, with: edit.replacement, selecting: edit.selection)
    }

    /// One undoable replacement through UIKit's text input, so the undo
    /// manager, the delegate and the document all see it.
    func replace(_ range: NSRange, with replacement: String, selecting selection: NSRange) {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return }
        replace(textRange, withText: replacement)
        selectedRange = selection.clamped(to: textStorage.length)
    }

    private func isCode(at location: Int) -> Bool {
        guard location < textStorage.length,
              let font = textStorage.attribute(.font, at: location, effectiveRange: nil) as? UIFont else { return false }
        return font == Appearance.codeFont()
    }

    private func replaceTypedArrow() {
        guard selectedRange.length == 0 else { return }
        let caret = selectedRange.location
        let text = textStorage.string as NSString
        guard caret >= 2, caret <= text.length,
              text.character(at: caret - 1) == 0x3E, text.character(at: caret - 2) == 0x2D else { return }
        if caret >= 3, [0x2D, 0x3C].contains(text.character(at: caret - 3)) { return }
        guard !isCode(at: caret - 2) else { return }
        replace(NSRange(location: caret - 2, length: 2), with: "→", selecting: NSRange(location: caret - 1, length: 0))
    }

    private func replaceTypedDashes() {
        guard selectedRange.length == 0 else { return }
        let caret = selectedRange.location
        let text = textStorage.string as NSString
        guard caret >= 3, caret <= text.length,
              ![0x2D, 0x3E].contains(text.character(at: caret - 1)),
              text.character(at: caret - 2) == 0x2D,
              text.character(at: caret - 3) == 0x2D else { return }
        if caret >= 4, [0x2D, 0x7C, 0x3A, 0x3C, 0x3E].contains(text.character(at: caret - 4)) { return }
        guard !isCode(at: caret - 2) else { return }
        replace(NSRange(location: caret - 3, length: 2), with: "—", selecting: NSRange(location: caret - 1, length: 0))
    }

    private static let taskBoxLeadPattern = try! NSRegularExpression(
        pattern: #"^[\t ]*(?:>[\t ]?)*(?:(?:[-+*]|\d+[A-Za-z]?[.)]|(?=[ivx]{2,}[.)])x{0,3}(?:ix|iv|v?i{0,3})[.)]|(?=[IVX]{2,}[.)])X{0,3}(?:IX|IV|V?I{0,3})[.)]|[A-Za-z][.)])[\t ]+)?$"#
    )

    private func replaceTypedTaskBox() {
        guard selectedRange.length == 0 else { return }
        let caret = selectedRange.location
        let text = textStorage.string as NSString
        guard caret >= 2, caret <= text.length,
              text.character(at: caret - 1) == 0x5D, text.character(at: caret - 2) == 0x5B else { return }
        let paragraph = text.paragraphRange(for: NSRange(location: caret, length: 0))
        let lead = NSRange(location: paragraph.location, length: caret - 2 - paragraph.location)
        guard let match = Self.taskBoxLeadPattern.firstMatch(in: text as String, range: lead),
              match.range == lead, !isCode(at: caret - 2) else { return }
        let leadText = text.substring(with: lead)
        let hasMarker = MarkdownSyntaxStyler.listMarkerPattern.firstMatch(
            in: leadText, range: NSRange(location: 0, length: leadText.utf16.count)
        ) != nil
        let replacement = hasMarker ? "[ ] " : "- [ ] "
        replace(
            NSRange(location: caret - 2, length: 2), with: replacement,
            selecting: NSRange(location: caret - 2 + replacement.utf16.count, length: 0)
        )
    }

    // MARK: - Taps

    /// What a tap at a point (view coordinates) does instead of placing
    /// the caret: flip a task, or follow a link.
    enum TapAction: Equatable {
        case toggleTask(prefix: NSRange)
        case link(String)
    }

    func tapAction(at point: CGPoint) -> TapAction? {
        guard textStorage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let index = paperLayoutManager.characterIndex(
            for: local, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        guard index < textStorage.length else { return nil }
        var prefix = NSRange(location: NSNotFound, length: 0)
        if textStorage.attribute(.taskBox, at: index, longestEffectiveRange: &prefix,
                                 in: NSRange(location: 0, length: textStorage.length)) != nil,
           let circle = DecorationView.taskCircleRect(forPrefix: prefix, layoutManager: paperLayoutManager, storage: textStorage),
           circle.insetBy(dx: -8, dy: -8).contains(local) {
            return .toggleTask(prefix: prefix)
        }
        if let destination = textStorage.attribute(.linkDestination, at: index, effectiveRange: nil) as? String {
            // Only on the link's glyphs, not past the end of its line.
            let glyph = paperLayoutManager.glyphIndexForCharacter(at: index)
            let bounds = paperLayoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            if bounds.insetBy(dx: -4, dy: -4).contains(local) { return .link(destination) }
        }
        return nil
    }

    func perform(_ action: TapAction) {
        switch action {
        case .toggleTask(let prefix):
            let inner = NSRange(location: NSMaxRange(prefix) - 2, length: 1)
            let done = (textStorage.string as NSString).substring(with: inner) != " "
            let keep = selectedRange
            replace(inner, with: done ? " " : "x", selecting: keep)
        case .link(let destination):
            if destination.hasPrefix("#") {
                guard let range = MarkdownSyntaxStyler.fragmentRange(destination, in: textStorage.string) else { return }
                selectedRange = NSRange(location: range.location, length: 0)
                scrollRangeToVisible(range)
            } else if MarkdownResource.isRemote(destination), let url = URL(string: destination) {
                UIApplication.shared.open(url)
            }
        }
    }

    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let action = tapAction(at: recognizer.location(in: self)) else { return }
        perform(action)
    }

    /// A tap on a task circle or a link does that and nothing else: the
    /// text view's own taps, which would place the caret, stand down.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        let hasAction = tapAction(at: recognizer.location(in: self)) != nil
        if recognizer === actionTap { return hasAction }
        if hasAction, recognizer is UITapGestureRecognizer { return false }
        return super.gestureRecognizerShouldBegin(recognizer)
    }

    // MARK: - Tables and the caret

    /// A tap on a drawn table cell lands on the source character under it;
    /// the row is one concealed line, so the text system would put every
    /// tap at the row's start.
    override func closestPosition(to point: CGPoint) -> UITextPosition? {
        if let index = tableSourceIndex(at: point) {
            return position(from: beginningOfDocument, offset: index)
        }
        return super.closestPosition(to: point)
    }

    func tableSourceIndex(at point: CGPoint) -> Int? {
        guard textStorage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = paperLayoutManager.glyphIndex(for: local, in: textContainer)
        let fragment = paperLayoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard local.y >= fragment.minY, local.y < fragment.maxY else { return nil }
        let rows = paperLayoutManager.tableRows(forGlyphRange: NSRange(location: glyph, length: 1))
        guard let row = rows.first, !row.active, row.mark.kind != .delimiter,
              local.y < row.bottom, row.mark.row < row.mark.layout.rows.count else { return nil }
        let layout = row.mark.layout
        let cells = layout.rows[row.mark.row]
        let x = local.x - textContainer.lineFragmentPadding
        guard let index = layout.column(at: x) else { return nil }
        guard index < cells.count else { return cells.last?.sourceOffsets.last }
        let cell = cells[index]
        let column = layout.columns[index]
        let offset = TableMeasure.offset(
            in: cell.text, width: column.width,
            at: CGPoint(x: x - column.x, y: local.y - row.top - layout.padding)
        )
        return cell.sourceOffsets[min(offset, cell.sourceOffsets.count - 1)]
    }

    /// The caret stands on the line's baseline, as tall as the tallest
    /// font on its paragraph, as on the Mac. UIKit's proposed rect spans
    /// the line fragment, and on iOS that includes the paragraph spacing
    /// below a paragraph's last line, so the caret is placed from the
    /// baseline instead of from the rect's edges.
    override func caretRect(for position: UITextPosition) -> CGRect {
        let proposed = super.caretRect(for: position)
        let index = offset(from: beginningOfDocument, to: position)
        let font = caretFont(at: index)
        let overshoot = Appearance.caretOvershoot
        guard let baseline = baseline(at: index) else { return proposed }
        return CGRect(
            x: proposed.minX,
            y: baseline - font.ascender - overshoot,
            width: proposed.width,
            height: font.ascender - font.descender + overshoot * 2
        )
    }

    /// The baseline, in view coordinates, of the line holding the caret at
    /// `index`: the line of the character there, or of the last character
    /// when the caret ends the text, or the empty line after a final
    /// newline.
    func baseline(at index: Int) -> CGFloat? {
        let layoutManager = paperLayoutManager
        let length = textStorage.length
        let origin = textContainerOrigin
        let text = textStorage.string as NSString
        if length == 0 || (index >= length && text.character(at: length - 1) == 0x0A) {
            let extra = layoutManager.extraLineFragmentRect
            guard !extra.isEmpty else { return nil }
            // TextKit 1 sets the line-height multiple's extra space above
            // the glyphs; the line's own height ends at the descent.
            let body = Appearance.bodyFont()
            let lineHeight = layoutManager.defaultLineHeight(for: body) * Appearance.lineHeightMultiple
            return origin.y + extra.minY + lineHeight + body.descender
        }
        let character = min(index, length - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        // On an empty line TextKit places the newline glyph at the bottom
        // of the line rather than on its baseline, one descent lower; the
        // baseline is the used rect's bottom less the descent, as for text.
        if text.character(at: character) == 0x0A, character == 0 || text.character(at: character - 1) == 0x0A {
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let font = textStorage.attribute(.font, at: character, effectiveRange: nil) as? UIFont ?? Appearance.bodyFont()
            return origin.y + used.maxY + font.descender
        }
        let location = layoutManager.location(forGlyphAt: glyph)
        return origin.y + fragment.minY + location.y
    }

    private func caretFont(at location: Int) -> UIFont {
        let body = Appearance.bodyFont()
        guard textStorage.length > 0 else { return body }
        let paragraph = (textStorage.string as NSString).paragraphRange(
            for: NSRange(location: min(location, textStorage.length), length: 0)
        )
        guard paragraph.length > 0 else { return body }
        var tallest = body
        textStorage.enumerateAttribute(.font, in: paragraph) { value, _, _ in
            if let font = value as? UIFont, font.pointSize > tallest.pointSize { tallest = font }
        }
        return tallest
    }
}
