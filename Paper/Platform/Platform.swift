#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The engine shared by the Mac and iOS apps (the styler, the layout manager,
// tables, math, images, appearance, configuration) is written against
// AppKit's names. On iOS those names are mapped here onto UIKit's, so the
// shared files read the same on both platforms and the Mac's code is
// unchanged. Only what the shared files use is mapped.

#if os(iOS)
typealias NSColor = UIColor
typealias NSFont = UIFont
typealias NSFontDescriptor = UIFontDescriptor
typealias NSImage = UIImage
typealias NSBezierPath = UIBezierPath
typealias NSEdgeInsets = UIEdgeInsets
typealias NSRect = CGRect
typealias NSPoint = CGPoint
typealias NSSize = CGSize
#endif

/// What the styler needs from the text view it styles. `PaperTextView` on
/// the Mac and `MobileTextView` on iOS conform; the styler sees nothing
/// else of either.
@MainActor
protocol StyledSurface: AnyObject {
    var surfaceStorage: NSTextStorage? { get }
    var surfaceContainer: NSTextContainer? { get }
    var surfaceSelection: NSRange { get set }
    var surfaceTypingAttributes: [NSAttributedString.Key: Any] { get set }
    /// The document's file, so relative images resolve; nil until saved.
    var surfaceDocumentURL: URL? { get }
    /// Whether this surface paginates for print or export (Mac only).
    var surfaceIsPrinting: Bool { get }
    /// The export style's page settings while printing (Mac only).
    var surfacePrintPage: PrintStyle.Page? { get }
    /// Removes spelling and grammar marks the checker left on code.
    func surfaceClearCheckingMarksInCode(in range: NSRange)
    /// Watches the given image files for changes on disk.
    func surfaceWatchImages(_ urls: Set<URL>)
}

#if os(iOS)
extension NSAttributedString.Key {
    /// The Mac's pointer-shape attribute. Nothing sets it on iOS; the
    /// styler names it only to clear it, so the name is all that is needed.
    static let cursor = NSAttributedString.Key("NSCursor")
}
#endif

#if os(iOS)
extension NSString {
    typealias DrawingOptions = NSStringDrawingOptions
}
#endif

#if os(iOS)
extension UIBezierPath {
    /// AppKit's spelling; UIKit's paths round both axes alike.
    convenience init(roundedRect rect: CGRect, xRadius: CGFloat, yRadius: CGFloat) {
        self.init(roundedRect: rect, cornerRadius: xRadius)
    }
}
#endif

#if os(iOS)
extension NSAttributedString {
    /// AppKit's spelling; UIKit's takes a drawing context, nil here.
    func boundingRect(with size: CGSize, options: NSStringDrawingOptions) -> CGRect {
        boundingRect(with: size, options: options, context: nil)
    }

    func draw(with rect: CGRect, options: NSStringDrawingOptions) {
        draw(with: rect, options: options, context: nil)
    }
}
#endif

#if os(iOS)
extension UIFontDescriptor.SymbolicTraits {
    static let bold = UIFontDescriptor.SymbolicTraits.traitBold
    static let italic = UIFontDescriptor.SymbolicTraits.traitItalic
}

extension NSLayoutManager {
    /// AppKit's line height for a font: ascender, descender and leading.
    func defaultLineHeight(for font: UIFont) -> CGFloat {
        font.lineHeight
    }
}
#endif
