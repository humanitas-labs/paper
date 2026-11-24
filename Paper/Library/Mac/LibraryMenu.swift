import AppKit
import SwiftUI

/// One line of the library's menu.
struct LibraryMenuItem: Identifiable {
    let id = UUID()
    let title: String
    /// A line glyph on the library's 24 pt grid.
    let glyph: AnyShape
    var hint: String = ""
    let action: () -> Void

    init(title: String, glyph: some Shape, hint: String = "", action: @escaping () -> Void) {
        self.title = title
        self.glyph = AnyShape(glyph)
        self.hint = hint
        self.action = action
    }
}

/// A right click in the library: where it landed, in the window's content
/// from its top left, and what it offers.
struct LibraryMenuRequest: Identifiable {
    let id = UUID()
    let point: CGPoint
    let items: [LibraryMenuItem]
}

/// The library's menu, after Spatial's: a soft wash settles over the grid
/// and a rounded card grows out from the pointer. A click on a line acts
/// and closes it; a click anywhere else, or Escape, only closes it.
struct LibraryMenuLayer: View {
    @Binding var request: LibraryMenuRequest?

    static let width: CGFloat = 292
    static let rowHeight: CGFloat = 42
    static let inset: CGFloat = 8
    static let grow = Animation.spring(duration: 0.32, bounce: 0.22)
    static let wash = Animation.easeOut(duration: 0.22)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let request {
                    LibraryPalette.background.opacity(0.72)
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .transition(.opacity.animation(Self.wash))
                    let place = placement(for: request, in: proxy.size)
                    LibraryMenuCard(items: request.items, close: close)
                        .frame(width: Self.width)
                        // Out from the pointer: the click stays put while
                        // the card grows away from it.
                        .transition(
                            .scale(scale: 0.4, anchor: place.anchor).combined(with: .opacity)
                                .animation(Self.grow)
                        )
                        .id(request.id)
                        .offset(x: place.origin.x, y: place.origin.y)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .onExitCommand { close() }
    }

    private func close() {
        withAnimation(Self.wash) { request = nil }
    }

    /// The card opens down and to the right of the pointer, and turns the
    /// other way at the window's edges. It grows from the pointer: the
    /// anchor is the click, in the card's own unit square.
    private func placement(for request: LibraryMenuRequest, in size: CGSize) -> (origin: CGPoint, anchor: UnitPoint) {
        let height = CGFloat(request.items.count) * Self.rowHeight + Self.inset * 2
        let margin: CGFloat = 12
        var x = request.point.x
        var y = request.point.y
        if x + Self.width + margin > size.width { x = request.point.x - Self.width }
        if y + height + margin > size.height { y = request.point.y - height }
        x = min(max(x, margin), max(size.width - Self.width - margin, margin))
        y = min(max(y, margin), max(size.height - height - margin, margin))
        let anchor = UnitPoint(x: (request.point.x - x) / Self.width, y: (request.point.y - y) / height)
        return (CGPoint(x: x, y: y), anchor)
    }
}

private struct LibraryMenuCard: View {
    let items: [LibraryMenuItem]
    let close: () -> Void
    static let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                LibraryMenuRow(item: item) {
                    close()
                    item.action()
                }
            }
        }
        .padding(LibraryMenuLayer.inset)
        .background {
            Self.shape
                .fill(MenuPalette.fill)
                .shadow(color: .black.opacity(MenuPalette.shadowOpacity), radius: 30, y: 22)
        }
        .overlay(Self.shape.strokeBorder(MenuPalette.rim, lineWidth: 1))
    }
}

private struct LibraryMenuRow: View {
    let item: LibraryMenuItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                item.glyph
                    .stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .frame(width: 20, height: 20)
                    .frame(width: 22)
                Text(item.title)
                    .font(.system(size: 14, weight: .regular))
                    .lineLimit(1)
                Spacer(minLength: 12)
                if !item.hint.isEmpty {
                    Text(item.hint)
                        .font(.system(size: 13))
                        .foregroundStyle(MenuPalette.hint)
                }
            }
            .foregroundStyle(MenuPalette.ink)
            .padding(.horizontal, 16)
            .frame(height: LibraryMenuLayer.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(MenuPalette.hover.opacity(hovering ? 1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

@MainActor
enum MenuPalette {
    static let fill = color(dark: 0x1D1F20, light: 0xF3F4F5)
    static let rim = color(dark: 0x2B2D2F, light: 0xF8F9FA)
    static let ink = color(dark: 0xECEDEE, light: 0x1D2023)
    static let hint = color(dark: 0x8A8F96, light: 0x86898D)
    static let hover = color(dark: 0x2A2C2E, light: 0xE7E9EB)
    static var shadowOpacity: Double { 0.28 }

    private static func color(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
        })
    }
}
