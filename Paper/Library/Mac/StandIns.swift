// TEMPORARY: copies of the iOS library's portable views until DL-01 moves
// them to Paper/Library/ on feat/ios. Dropped at the rebase onto it.
import AppKit
import SwiftUI

enum LibraryPalette {
    static let background = dynamic(dark: 0x0C0D0D, light: 0xE8EAEB)
    static let card = dynamic(dark: 0x111212, light: 0xFFFFFF)
    static let border = dynamic(dark: 0x1F2020, light: 0xFFFFFF)
    static let secondaryLabel = dynamic(dark: 0x959EAC, light: 0x6B7280)

    static func nsColor(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }

    private static func dynamic(dark: UInt32, light: UInt32) -> Color { Color(nsColor: nsColor(dark: dark, light: light)) }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }
}

/// Marina's folder primitive: the layered folder shape, the item count
/// and the name at its lower left.
struct FolderCard: View {
    let folder: FolderListing.Folder
    var selected = false

    /// The artwork draws the folder inside a larger canvas (room for its
    /// shadow): the shape spans x 10.5–301.6 and y 4.5–210 of 312 × 226.
    /// The card is sized by the shape, so its edges meet the grid's like a
    /// note card's, and the artwork overhangs it by the shadow's margin.
    static let canvas = CGSize(width: 312.054, height: 226.45)
    static let shape = CGRect(x: 10.5, y: 4.5, width: 291.054, height: 205.45)

    var body: some View {
        // The shadow is the grid's, cast by `FolderCard.shadow` outside the
        // zoom source, whose clip hid it around a zoom.
        Color.clear
            .aspectRatio(Self.shape.width / Self.shape.height, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let scale = proxy.size.width / Self.shape.width
                    Image("FolderShape")
                        .resizable()
                        .frame(width: Self.canvas.width * scale, height: Self.canvas.height * scale)
                        .offset(x: -Self.shape.minX * scale, y: -Self.shape.minY * scale)
                }
            }
            .overlay(alignment: .bottomLeading) {
                // The label sits 26 pt in from the shape's left and ends
                // about 26 pt above its bottom on the 291 pt design folder;
                // anchored at the bottom, it cannot run past the card.
                GeometryReader { proxy in
                    let scale = proxy.size.width / Self.shape.width
                    label(scale: scale)
                        .frame(width: proxy.size.width * 0.78, alignment: .leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.leading, 29.5 * scale)
                        .padding(.bottom, 37 * scale)
                }
            }
            // Picked: a bright outline around the folder's silhouette.
            .overlay {
                if selected { FolderSilhouette().stroke(Color.primary, style: StrokeStyle(lineWidth: 3, lineJoin: .round)) }
            }
            .animation(.easeOut(duration: 0.15), value: selected)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The folder's shadow, from a plain silhouette laid under the card:
    /// the artwork's own SVG shadow does not render, and a shadow traced
    /// from the artwork caught the tab's corner hard.
    static var shadow: some View {
        FolderSilhouette()
            .fill(LibraryPalette.background)
            .modifier(CardShadow())
    }

    /// Spatial's label: the count and the name at one size in the system
    /// sans, regular weight, the count in a soft gray. Sized from the card,
    /// about 5% of its width, so the type scales with the folder.
    private func label(scale: CGFloat) -> some View {
        let size = 15.5 * scale
        return VStack(alignment: .leading, spacing: 2.5 * scale) {
            Text(folder.itemCount == 1 ? "1 item" : "\(folder.itemCount) items")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(FolderCard.countInk)
            Text(folder.name)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(FolderCard.nameInk)
                .lineLimit(1)
        }
    }

    static let countInk = Color(nsColor: LibraryPalette.nsColor(dark: 0x959EAC, light: 0x6E7073))
    static let nameInk = Color(nsColor: LibraryPalette.nsColor(dark: 0xF2F3F4, light: 0x1A1C1F))
}

/// The folder artwork's outline (its back panel and tab), fitted to the
/// card, which is the shape's own box, for the picked state's ring.
struct FolderSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        // Artwork coordinates, measured from the shape's own top left.
        let box = FolderCard.shape
        let sx = rect.width / box.width, sy = rect.height / box.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - box.minX) * sx, y: rect.minY + (y - box.minY) * sy)
        }
        var path = Path()
        path.move(to: p(10.5, 22.844))
        path.addCurve(to: p(28.844, 4.5), control1: p(10.5, 10.615), control2: p(16.615, 4.5))
        path.addLine(to: p(104.665, 4.5))
        path.addCurve(to: p(121.785, 11.837), control1: p(111.187, 4.5), control2: p(116.894, 6.946))
        path.addLine(to: p(136.46, 26.512))
        path.addCurve(to: p(151.135, 31.404), control1: p(139.722, 29.774), control2: p(144.613, 31.404))
        path.addLine(to: p(283.21, 31.404))
        path.addCurve(to: p(301.554, 49.748), control1: p(295.44, 31.404), control2: p(301.554, 37.519))
        path.addLine(to: p(301.554, 191.606))
        path.addCurve(to: p(283.21, 209.95), control1: p(301.554, 203.835), control2: p(295.44, 209.95))
        path.addLine(to: p(28.844, 209.95))
        path.addCurve(to: p(10.5, 191.606), control1: p(16.615, 209.95), control2: p(10.5, 203.835))
        path.closeSubpath()
        return path
    }
}

/// Spatial-style compose glyph on a 24 pt grid: a rounded page open at its
/// top right corner, and a pen stroke running into it.
struct ComposeGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        // The page: from the top edge round the left, bottom and right.
        path.move(to: p(11, 4))
        path.addLine(to: p(8, 4))
        path.addQuadCurve(to: p(4, 8), control: p(4, 4))
        path.addLine(to: p(4, 16))
        path.addQuadCurve(to: p(8, 20), control: p(4, 20))
        path.addLine(to: p(16, 20))
        path.addQuadCurve(to: p(20, 16), control: p(20, 20))
        path.addLine(to: p(20, 13))
        // The pen: a stroke from the top right into the page.
        path.move(to: p(19.5, 4.5))
        path.addLine(to: p(11, 13))
        return path
    }
}

/// A pencil on the toast glyphs' 24 pt grid: a slanted body with a
/// rounded tip at the lower left and a band below its end.
struct PencilGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        // As tall as the folder and the bin: about 4–20 on the grid.
        path.move(to: p(15.9, 4.2))
        path.addLine(to: p(19.8, 8.1))
        path.addLine(to: p(8.75, 19.15))
        path.addLine(to: p(3.6, 20.4))
        path.addLine(to: p(4.85, 15.25))
        path.closeSubpath()
        path.move(to: p(13.3, 6.8))
        path.addLine(to: p(17.2, 10.7))
        return path
    }
}

/// A folder on the toast glyphs' 24 pt grid: a rounded body whose tab
/// steps down at the top left.
struct FolderGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(3, 8))
        path.addQuadCurve(to: p(6, 5), control: p(3, 5))
        path.addLine(to: p(9, 5))
        path.addQuadCurve(to: p(10.9, 5.8), control: p(10.2, 5))
        path.addLine(to: p(12.1, 7))
        path.addQuadCurve(to: p(14, 7.8), control: p(12.8, 7.8))
        path.addLine(to: p(18, 7.8))
        path.addQuadCurve(to: p(21, 10.8), control: p(21, 7.8))
        path.addLine(to: p(21, 16))
        path.addQuadCurve(to: p(18, 19), control: p(21, 19))
        path.addLine(to: p(6, 19))
        path.addQuadCurve(to: p(3, 16), control: p(3, 19))
        path.closeSubpath()
        return path
    }
}

/// A bin on the toast glyphs' 24 pt grid: a lid with a flat handle over a
/// tapered body.
struct TrashGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        // The lid and its handle.
        path.move(to: p(3.5, 6.5))
        path.addLine(to: p(20.5, 6.5))
        path.move(to: p(9, 6.5))
        path.addLine(to: p(9, 5))
        path.addQuadCurve(to: p(10.5, 3.5), control: p(9, 3.5))
        path.addLine(to: p(13.5, 3.5))
        path.addQuadCurve(to: p(15, 5), control: p(15, 3.5))
        path.addLine(to: p(15, 6.5))
        // The body, narrowing to a rounded foot.
        path.move(to: p(5.5, 6.5))
        path.addLine(to: p(6.7, 18))
        path.addQuadCurve(to: p(8.9, 20), control: p(6.9, 20))
        path.addLine(to: p(15.1, 20))
        path.addQuadCurve(to: p(17.3, 18), control: p(17.1, 20))
        path.addLine(to: p(18.5, 6.5))
        return path
    }
}

/// A note card's shadow, matched to the folder artwork's own: a soft
/// fall-off, light in light mode and deeper in dark, where a light one
/// would not show.
struct CardShadow: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if colorScheme == .dark {
            content.shadow(color: .black.opacity(0.45), radius: 8, y: 4)
        } else {
            content.shadow(color: .black.opacity(0.08), radius: 8, y: 4)
        }
    }
}

@MainActor
enum LibraryMotion {
    static let itemTransition = AnyTransition.scale(scale: 0.6).combined(with: .opacity)
    static let itemSpring = Animation.spring(duration: 0.4, bounce: 0.18)
    static let selectionSpring = Animation.spring(duration: 0.35, bounce: 0.15)
}

struct NoteCard: View {
    static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    static let aspect: CGFloat = 470.0 / 668.0
    let note: FolderListing.Note
    var selected = false
    var miniature: Image?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NoteCard.shape
            .fill(LibraryPalette.card)
            .aspectRatio(Self.aspect, contentMode: .fit)
            .overlay {
                if let miniature {
                    miniature.resizable().scaledToFill()
                } else {
                    Text(note.title)
                        .font(Font(Appearance.headingFont(size: 11)))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(10)
                }
            }
            .clipShape(NoteCard.shape)
            .overlay {
                if colorScheme == .dark { NoteCard.shape.strokeBorder(LibraryPalette.border, lineWidth: 1) }
            }
            .overlay {
                if selected { NoteCard.shape.strokeBorder(Color.primary, lineWidth: 3) }
            }
            .animation(.easeOut(duration: 0.15), value: selected)
            .contentShape(NoteCard.shape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(note.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
