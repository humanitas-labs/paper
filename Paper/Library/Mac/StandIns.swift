// TEMPORARY: copies of the iOS library's portable views until DL-01 moves
// them to Paper/Library/ on feat/ios. Dropped at the rebase onto it.
import AppKit
import SwiftUI

/// A picked card's ring: the system's blue, 2 pt, on the card's edge.
enum LibrarySelectionRing {
    static let color = Color(nsColor: .systemBlue)
    static let width: CGFloat = 2
}

enum LibraryPalette {
    /// The theme's surfaces (`color.surface.*`), so the library wears the
    /// theme the notes do and a theme can tune its shades. Unset, they
    /// derive from the canvas: on the light page a note is the page
    /// itself, a card on a dimmed ground, as in Spatial; on the dark page
    /// the ground is the page and a card is lifted a little off it.
    static let background = themed { _ in Appearance.surfaceGround }
    static let card = themed { _ in Appearance.surfaceCard }
    static let border = themed { dark in dark ? Appearance.surfaceBorder : .white }

    /// The note card's color in an appearance, resolved now.
    @MainActor
    static func resolvedCard(dark: Bool) -> NSColor {
        var card = NSColor.white
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            card = Appearance.surfaceCard.usingColorSpace(.sRGB) ?? .white
        }
        return card
    }

    /// The folder's fine rim in dark mode: halfway between the card and
    /// the border, which read harsh around a folder.
    static let folderRim = themed { dark in
        guard dark, let card = Appearance.surfaceCard.usingColorSpace(.sRGB) else { return .clear }
        return card.blended(withFraction: 0.5, of: Appearance.surfaceBorder) ?? card
    }
    static let secondaryLabel = dynamic(dark: 0x959EAC, light: 0x6B7280)

    static func nsColor(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }

    /// A color from the theme in each appearance, read as it draws, so a
    /// theme change shows once the library redraws.
    private static func themed(_ make: @escaping @MainActor (Bool) -> NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            var color = NSColor.white
            appearance.performAsCurrentDrawingAppearance {
                color = MainActor.assumeIsolated { make(dark) }.usingColorSpace(.sRGB) ?? .white
            }
            return color
        })
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
    @Environment(\.colorScheme) private var colorScheme

    /// The folder in the iPhone artwork's coordinates: x 10.5–301.6 and
    /// y 4.5–210. The card is sized by it, so its edges meet the grid's
    /// like a note card's.
    static let shape = CGRect(x: 10.5, y: 4.5, width: 291.054, height: 205.45)

    var body: some View {
        // The shadow is the grid's, cast by `FolderCard.shadow` outside the
        // zoom source, whose clip hid it around a zoom.
        Color.clear
            .aspectRatio(Self.shape.width / Self.shape.height, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let scale = proxy.size.width / Self.shape.width
                    // Drawn, not an image, so the front is the note
                    // card's own color in every theme.
                    let colors = FolderCard.colors(dark: colorScheme == .dark)
                    // In dark mode each panel has a fine rim, as the
                    // iPhone's dark artwork does.
                    let rim = colorScheme == .dark ? LibraryPalette.folderRim : .clear
                    ZStack {
                        FolderSilhouette().fill(Color(nsColor: colors.back))
                            .overlay(FolderSilhouette().stroke(rim, lineWidth: 1))
                        FolderSilhouette(panel: .paper).fill(Color(nsColor: colors.paper))
                            .overlay(FolderSilhouette(panel: .paper).stroke(rim, lineWidth: 1))
                        FolderSilhouette(panel: .front).fill(Color(nsColor: colors.front))
                            .overlay(FolderSilhouette(panel: .front).stroke(rim, lineWidth: 1))
                            // The front's lip casts up onto the back.
                            .shadow(color: .black.opacity(0.09 * scale), radius: 2 * scale, y: -2 * scale)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .overlay(alignment: .bottomLeading) {
                // The label sits 21 pt in from the shape's left and ends
                // about 26 pt above its bottom on the 291 pt design folder;
                // anchored at the bottom, it cannot run past the card.
                GeometryReader { proxy in
                    let scale = proxy.size.width / Self.shape.width
                    label(scale: scale)
                        .frame(width: proxy.size.width * 0.78, alignment: .leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.leading, 21 * scale)
                        .padding(.bottom, 22 * scale)
                }
            }
            // Picked: a ring in the system's blue, which reads at once on
            // the pale page and the dark one.
            .overlay {
                if selected {
                    FolderSilhouette().stroke(LibrarySelectionRing.color, style: StrokeStyle(lineWidth: LibrarySelectionRing.width, lineJoin: .round))
                }
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
    /// sans, regular weight, the count in a soft gray. Spatial sets it
    /// near 20 pt, where the system face is the tighter display cut; at a
    /// card's smaller size the same look needs the letters drawn in a
    /// little. Sized from the card (5.6% of its width), so it scales.
    private func label(scale: CGFloat) -> some View {
        let size = 16.3 * scale
        // The count a step down from the name, so the name leads.
        let countSize = 13 * scale
        return VStack(alignment: .leading, spacing: 2.4 * scale) {
            Text(folder.itemCount == 1 ? "1 item" : "\(folder.itemCount) items")
                .font(.system(size: countSize, weight: .regular))
                .tracking(-0.01 * countSize)
                .foregroundStyle(FolderCard.countInk)
            Text(folder.name)
                .font(.system(size: size, weight: .regular))
                .tracking(-0.022 * size)
                .foregroundStyle(FolderCard.nameInk)
                .lineLimit(1)
        }
    }

    /// The folder's panels from the note card's color: the front is the
    /// card, the back a step darker, the paper inside a step lighter, as
    /// in the iPhone's artwork (#ECEEEF, #F8F9FA, #F3F4F5 in light).
    static func colors(dark: Bool) -> (back: NSColor, paper: NSColor, front: NSColor) {
        let card = LibraryPalette.resolvedCard(dark: dark)
        return (
            card.blended(withFraction: dark ? 0.12 : 0.03, of: .black) ?? card,
            card.blended(withFraction: dark ? 0.03 : 0.02, of: .white) ?? card,
            card
        )
    }

    static let countInk = Color(nsColor: LibraryPalette.nsColor(dark: 0x959EAC, light: 0x6E7073))
    static let nameInk = Color(nsColor: LibraryPalette.nsColor(dark: 0xF2F3F4, light: 0x1A1C1F))
}

/// The folder's panels from the iPhone's artwork, fitted to the card,
/// which is the shape's own box. The back (with the tab) is the whole
/// outline, for the picked state's ring too.
struct FolderSilhouette: Shape {
    enum Panel { case back, paper, front }
    var panel = Panel.back

    func path(in rect: CGRect) -> Path {
        // Artwork coordinates, measured from the shape's own top left.
        let box = FolderCard.shape
        let sx = rect.width / box.width, sy = rect.height / box.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - box.minX) * sx, y: rect.minY + (y - box.minY) * sy)
        }
        var path = Path()
        switch panel {
        case .back: break
        case .paper:
            path.move(to: p(96.7076, 35.4909))
            path.addLine(to: p(221.403, 32.2257))
            path.addCurve(to: p(231.439, 41.7492), control1: p(226.804, 32.0842), control2: p(231.297, 36.3481))
            path.addLine(to: p(232.207, 71.0892))
            path.addCurve(to: p(222.683, 81.1259), control1: p(232.348, 76.4913), control2: p(228.085, 80.9845))
            path.addLine(to: p(97.9881, 84.3911))
            path.addCurve(to: p(87.9524, 74.8666), control1: p(92.587, 84.5326), control2: p(88.0938, 80.2687))
            path.addLine(to: p(87.1841, 45.5266))
            path.addCurve(to: p(96.7076, 35.4909), control1: p(87.0427, 40.1255), control2: p(91.3065, 35.6323))
            path.closeSubpath()
            return path
        case .front:
            path.move(to: p(27.621, 43.633))
            path.addLine(to: p(284.433, 43.633))
            path.addCurve(to: p(301.554, 60.754), control1: p(293.889, 43.633), control2: p(301.554, 51.298))
            path.addLine(to: p(301.554, 192.829))
            path.addCurve(to: p(284.433, 209.95), control1: p(301.554, 202.284), control2: p(293.889, 209.95))
            path.addLine(to: p(27.621, 209.95))
            path.addCurve(to: p(10.5, 192.829), control1: p(18.165, 209.95), control2: p(10.5, 202.284))
            path.addLine(to: p(10.5, 60.754))
            path.addCurve(to: p(27.621, 43.633), control1: p(10.5, 51.298), control2: p(18.165, 43.633))
            path.closeSubpath()
            return path
        }
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
    static let shape = NoteCardShape()
    static let aspect: CGFloat = 235.0 / 334.0
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
                if selected {
                    NoteCard.shape.strokeBorder(LibrarySelectionRing.color, lineWidth: LibrarySelectionRing.width)
                }
            }
            .animation(.easeOut(duration: 0.15), value: selected)
            .contentShape(NoteCard.shape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(note.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
enum ToastPalette {
    static let fill = Color(nsColor: LibraryPalette.nsColor(dark: 0x212426, light: 0xF1F1F0))
    static let border = Color(nsColor: LibraryPalette.nsColor(dark: 0x2E3133, light: 0xDEDEDC))
    static let glyph = Color(nsColor: LibraryPalette.nsColor(dark: 0xB9BEC4, light: 0x4B5057))
}

/// Spatial's note card outline: a continuous corner of 24 pt on a card
/// 235 pt wide, kept in that proportion at any size.
struct NoteCardShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let radius = max(rect.width * 24.0 / 235.0 - inset, 0)
        return Path(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerRadius: radius, style: .continuous)
    }

    func inset(by amount: CGFloat) -> NoteCardShape {
        NoteCardShape(inset: inset + amount)
    }
}

/// Spatial's two shadows under a note, both sized from the card's width:
/// a wide soft one falling 5% of the width below, and a close, faint one
/// hugging the edge. Their color is a near-black with a little blue.
struct NoteShadow: ViewModifier {
    @State private var width: CGFloat = 200
    private static let ink = Color(.sRGB, red: 0x09 / 255.0, green: 0x0B / 255.0, blue: 0x0D / 255.0)

    func body(content: Content) -> some View {
        content
            .background(
                NoteCard.shape
                    .fill(LibraryPalette.card)
                    .shadow(color: Self.ink.opacity(0.10), radius: width * 0.06, y: width * 0.05)
                    .shadow(color: Self.ink.opacity(0.06), radius: width * 0.01)
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
