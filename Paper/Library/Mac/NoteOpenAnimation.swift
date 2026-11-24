import AppKit
import QuartzCore

/// Opening a note from its card: the card's page lifts off the grid and
/// grows into the note's window. The real window opens unseen. Over the
/// whole screen a clear, click-through window carries one rounded layer
/// from the card's frame to the window's; inside it the page's text grows
/// to its real size and blends into a picture of the real window, lined up
/// on the text's own corner, so nothing jumps when the window takes over.
@MainActor
enum NoteOpenAnimation {
    static let duration: CFTimeInterval = 0.46
    static var timing: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.24, 1) }

    /// - Parameters:
    ///   - card: the card's frame on screen.
    ///   - cardColor: the card's fill, which the page starts as.
    static func open(_ url: URL, from card: NSRect?, cardColor: NSColor, library: NSWindow?) {
        let already = NSDocumentController.shared.document(for: url) != nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let card, !already, !reduceMotion, let screen = library?.screen ?? NSScreen.main else {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            return
        }
        let appearance = library?.effectiveAppearance ?? NSApp.effectiveAppearance
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // The page's text alone, on a clear ground, to travel over the
        // changing color beneath it.
        let text = (try? NoteFile.read(url)).map { String($0.prefix(NoteMiniature.characterLimit)) } ?? ""
        let page = NoteMiniature.render(text, documentURL: url, dark: dark, background: .clear)
        let stage = Stage(screen: screen, card: card, page: page, cardColor: cardColor, appearance: appearance)
        stage.window.orderFront(nil)

        // The note's window, caught as it first becomes main, before it
        // has drawn: it stays clear until the page reaches it.
        var observer: NSObjectProtocol?
        var finished = false
        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard !finished, window !== stage.window, window !== library, !(window is NSPanel) else { return }
                finished = true
                stopObserving()
                window.alphaValue = 0
                // A moment, so Paper has placed the window and laid out
                // its text, which the picture of it needs.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    stage.grow(into: window)
                }
            }
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            MainActor.assumeIsolated {
                guard error != nil, !finished else { return }
                finished = true
                stopObserving()
                stage.window.orderOut(nil)
            }
        }
        // A window that never comes must not leave the stage up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard !finished else { return }
            finished = true
            stopObserving()
            stage.window.orderOut(nil)
        }
    }

    /// The clear window over the screen and the layers that travel in it.
    /// Layer geometry runs from the top left, as the views' does.
    @MainActor
    private final class Stage {
        let window: NSWindow
        private let screen: NSScreen
        private let cardFrame: CGRect
        private let shadow = CALayer()
        private let sheet = CALayer()
        private let pageLayer = CALayer()
        private let pictureLayer = CALayer()
        private let appearance: NSAppearance

        init(screen: NSScreen, card: NSRect, page: NSImage, cardColor: NSColor, appearance: NSAppearance) {
            self.screen = screen
            self.appearance = appearance
            window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.appearance = appearance
            let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            content.wantsLayer = true
            content.layer?.isGeometryFlipped = true
            window.contentView = content
            cardFrame = Self.fromTop(card, in: screen)

            let radius = cardFrame.width * 24.0 / 235.0
            shadow.frame = cardFrame
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOpacity = 0
            shadow.shadowRadius = 22
            shadow.shadowOffset = CGSize(width: 0, height: 14)
            shadow.shadowPath = CGPath(
                roundedRect: CGRect(origin: .zero, size: cardFrame.size), cornerWidth: radius, cornerHeight: radius, transform: nil
            )
            sheet.frame = cardFrame
            sheet.cornerRadius = radius
            sheet.cornerCurve = .continuous
            sheet.masksToBounds = true
            appearance.performAsCurrentDrawingAppearance {
                sheet.backgroundColor = cardColor.cgColor
            }
            pictureLayer.opacity = 0
            pictureLayer.contentsGravity = .resize
            pageLayer.contents = page
            pageLayer.contentsGravity = .resize
            pageLayer.frame = CGRect(origin: .zero, size: cardFrame.size)
            sheet.addSublayer(pictureLayer)
            sheet.addSublayer(pageLayer)
            content.layer?.addSublayer(shadow)
            content.layer?.addSublayer(sheet)
        }

        /// A screen rectangle measured from the screen's top left.
        private static func fromTop(_ rect: NSRect, in screen: NSScreen) -> CGRect {
            CGRect(
                x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                width: rect.width, height: rect.height
            )
        }

        func grow(into real: NSWindow) {
            let target = Self.fromTop(real.frame, in: screen)
            // Where the note's text begins in its window, from the top
            // left: the page's text is brought to that corner at its real
            // size, so the two lie on each other as one gives way.
            var textOrigin = CGPoint(x: Appearance.minimumHorizontalMargin, y: Appearance.topMargin)
            if let content = real.contentView, let textView = Self.textView(in: content) {
                let inset = textView.textContainerInset
                let origin = textView.convert(NSPoint(x: inset.width, y: inset.height), to: content)
                textOrigin = CGPoint(x: origin.x, y: content.isFlipped ? origin.y : content.bounds.height - origin.y)
                pictureLayer.contents = Self.picture(of: content)
            }
            let pageSize = CGSize(width: NoteMiniature.pageWidth, height: NoteMiniature.pageWidth / NoteMiniature.aspect)
            let margins = NoteMiniature.margins
            let startScale = cardFrame.width / pageSize.width
            let pageEnd = CGRect(
                x: textOrigin.x - margins.width, y: textOrigin.y - margins.height,
                width: pageSize.width, height: pageSize.height
            )
            // The picture of the window at the page's scale, its text
            // corner under the page's, from first frame to last.
            let pictureStart = CGRect(
                x: (margins.width - textOrigin.x) * startScale, y: (margins.height - textOrigin.y) * startScale,
                width: target.width * startScale, height: target.height * startScale
            )
            let pictureEnd = CGRect(origin: .zero, size: target.size)
            let endRadius = Appearance.windowCornerRadius
            var canvas = sheet.backgroundColor
            appearance.performAsCurrentDrawingAppearance { canvas = Appearance.canvas.cgColor }

            CATransaction.begin()
            CATransaction.setAnimationDuration(NoteOpenAnimation.duration)
            CATransaction.setAnimationTimingFunction(NoteOpenAnimation.timing)
            CATransaction.setCompletionBlock { [window] in
                MainActor.assumeIsolated {
                    // The real window appears whole beneath the stage,
                    // which then leaves: never two half-clear windows.
                    real.alphaValue = 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { window.orderOut(nil) }
                }
            }
            move(sheet, to: target)
            animate(sheet, "cornerRadius", to: endRadius)
            animate(sheet, "backgroundColor", to: canvas as Any)
            move(shadow, to: target)
            animate(shadow, "shadowOpacity", to: Float(0.28))
            animate(shadow, "shadowPath", to: CGPath(
                roundedRect: CGRect(origin: .zero, size: target.size), cornerWidth: endRadius, cornerHeight: endRadius, transform: nil
            ))
            pictureLayer.frame = pictureStart
            move(pageLayer, to: pageEnd)
            move(pictureLayer, to: pictureEnd)
            // The page gives way to the picture over the second half.
            fade(pageLayer, from: 1, to: 0)
            fade(pictureLayer, from: 0, to: 1)
            CATransaction.commit()
        }

        private func move(_ layer: CALayer, to frame: CGRect) {
            let bounds = CGRect(origin: .zero, size: frame.size)
            let position = CGPoint(x: frame.midX, y: frame.midY)
            animate(layer, "bounds", to: bounds)
            animate(layer, "position", to: position)
        }

        private func animate(_ layer: CALayer, _ key: String, to value: Any) {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
            animation.toValue = value
            layer.add(animation, forKey: key)
            CATransaction.setDisableActions(true)
            layer.setValue(value, forKeyPath: key)
        }

        private func fade(_ layer: CALayer, from: Float, to: Float) {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [from, from, to]
            animation.keyTimes = [0, 0.35, 0.8]
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(animation, forKey: "opacity")
            CATransaction.setDisableActions(true)
            layer.opacity = to
        }

        private static func textView(in view: NSView) -> PaperTextView? {
            if let textView = view as? PaperTextView { return textView }
            for subview in view.subviews {
                if let found = textView(in: subview) { return found }
            }
            return nil
        }

        private static func picture(of view: NSView) -> CGImage? {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.cgImage
        }
    }
}
