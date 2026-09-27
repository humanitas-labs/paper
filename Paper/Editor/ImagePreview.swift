import AppKit
import Quartz

/// A double-click on a block image opens it in the system Quick Look panel,
/// the way Messages opens a photo: zoomed out of the band, with ← → across
/// the document's images and Open with Preview one click away. The panel
/// is the system's; Paper adds nothing to it. Only files the document
/// resolves on disk take part: a remote image has no file to show.
extension PaperTextView: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    /// Every image band on the page in document order, in view coordinates.
    var imageBands: [(rect: NSRect, url: URL)] {
        guard let layoutManager = layoutManager as? PaperLayoutManager,
              let storage = textStorage, storage.length > 0 else { return [] }
        let origin = textContainerOrigin
        let all = layoutManager.glyphRange(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        return layoutManager.imageBands(forGlyphRange: all, width: MarkdownSyntaxStyler.measure(of: self))
            .filter(\.url.isFileURL)
            .map { (rect: $0.rect.offsetBy(dx: origin.x, dy: origin.y), url: $0.url) }
    }

    /// What the Quick Look panel steps through: the page's images and its
    /// formulas (as their enlarged PDFs), in document order, each with the
    /// rect it occupies on the page.
    var previewItems: [(rect: NSRect, url: URL)] {
        let formulas = mathFigures().compactMap { figure in
            MathStore.shared.previewFile(for: figure.latex).map { (rect: figure.formula, url: $0) }
        }
        return (imageBands + formulas).sorted { $0.rect.minY < $1.rect.minY }
    }

    /// The I-beam belongs to text; over an image the plain arrow, as in
    /// Messages, and over a code block's copy icon the hand. The text view
    /// sets its cursor on every mouse move, over any cursor rects, so the
    /// move itself is where the other cursors go in.
    /// Moves reach the first responder, so the text view hears them even
    /// when the pointer is over a badge in a corner; those own their own
    /// pointer, so the I-beam is not forced back over them.
    override func mouseMoved(with event: NSEvent) {
        if let content = window?.contentView, let hit = content.hitTest(event.locationInWindow), hit !== self, !hit.isDescendant(of: self) {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if codeCopyButtons.contains(where: { $0.isOnIcon(point) })
            || mathExpandButtons.contains(where: { !$0.isHidden && $0.alphaValue > 0 && $0.isOnIcon(point) }) {
            NSCursor.pointingHand.set()
        } else if imageURL(at: event) != nil {
            NSCursor.arrow.set()
        } else {
            super.mouseMoved(with: event)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if imageURL(at: event) != nil {
            NSCursor.arrow.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    /// A click that lands on an image is the image's: the caret stays where
    /// it was, so the source line is not revealed and the band does not
    /// jump under the pointer. A single click marks the image, as in
    /// Messages, and a double-click released on it opens it; a drag does
    /// nothing.
    func clickImage(with event: NSEvent) -> Bool {
        guard let image = imageURL(at: event), let window else { return false }
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            guard next.type == .leftMouseUp else { continue }
            guard imageURL(at: next) == image else { break }
            selectedImage = image
            if event.clickCount == 2 { preview(image) }
            break
        }
        return true
    }

    /// The mark: the ink at a quarter over the image, inside its corners.
    func drawImageSelection(in dirtyRect: NSRect) {
        guard let imageWash, imageWash.alpha > 0,
              let band = imageBands.first(where: { $0.url == imageWash.url }),
              band.rect.intersects(dirtyRect) else { return }
        Appearance.ink.withAlphaComponent(0.25 * imageWash.alpha).setFill()
        NSBezierPath(roundedRect: band.rect, xRadius: Appearance.imageCornerRadius, yRadius: Appearance.imageCornerRadius).fill()
    }

    /// The wash eases in when an image is marked and out when it is not,
    /// over a third of a second, on a display-rate timer since
    /// the band is drawn, not a layer.
    func animateImageWash() {
        imageWashTimer?.invalidate()
        if let selectedImage {
            imageWash = (selectedImage, imageWash?.url == selectedImage ? imageWash?.alpha ?? 0 : 0)
        }
        guard let start = imageWash else { return }
        let target: CGFloat = selectedImage == nil ? 0 : 1
        let from = start.alpha
        let began = CACurrentMediaTime()
        let duration = 0.35
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = min(1, (CACurrentMediaTime() - began) / duration)
                let eased = t * (2 - t)
                let alpha = from + (target - from) * eased
                self.imageWash = (start.url, alpha)
                if let band = self.imageBands.first(where: { $0.url == start.url }) {
                    self.setNeedsDisplay(band.rect.insetBy(dx: -1, dy: -1))
                }
                if t >= 1 {
                    self.imageWashTimer?.invalidate()
                    self.imageWashTimer = nil
                    if target == 0 { self.imageWash = nil }
                }
            }
        }
        // Common modes, so the fade runs through mouse tracking and scrolling.
        RunLoop.main.add(timer, forMode: .common)
        imageWashTimer = timer
    }

    /// Typing moves on from the image.
    override func keyDown(with event: NSEvent) {
        selectedImage = nil
        super.keyDown(with: event)
    }

    /// The image file drawn under `event`'s point, if any.
    func imageURL(at event: NSEvent) -> URL? {
        let point = convert(event.locationInWindow, from: nil)
        return imageBands.first { $0.rect.contains(point) }?.url
    }

    /// Shows the panel on `url`, which becomes the current item among the
    /// page's images and formulas. The panel asks up the responder chain
    /// for a data source; the text view is first responder, so it answers.
    func preview(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        window?.makeFirstResponder(self)
        panel.makeKeyAndOrderFront(nil)
        if let index = previewItems.firstIndex(where: { $0.url == url }) {
            panel.currentPreviewItemIndex = index
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let bands = previewItems
        guard bands.indices.contains(index) else { return nil }
        return bands[index].url as NSURL
    }

    /// The band's place on screen, so the panel zooms out of the page and
    /// back into it. A band scrolled out of view zooms from the centre.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item.previewItemURL,
              let band = previewItems.first(where: { $0.url == url }),
              band.rect.intersects(visibleRect),
              let window else { return .zero }
        return window.convertToScreen(convert(band.rect, to: nil))
    }
}
