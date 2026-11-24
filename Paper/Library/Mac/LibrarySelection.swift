import AppKit
import SwiftUI

/// The rubber band drawn while dragging across the library: a soft fill
/// in the ink's color inside a hairline, as Finder draws one.
struct MarqueeLayer: View {
    /// In the window's content, from its top left; nil when not dragging.
    let rect: CGRect?
    /// The rectangle last dragged, kept so it can fade where it was let go.
    @State private var last = CGRect.zero

    /// Spatial's white line and wash, on the light page as on the dark.
    private static let line = Color.white.opacity(0.9)
    private static let wash = Color.white.opacity(0.2)

    var body: some View {
        GeometryReader { _ in
            // Square-cornered, a light wash inside a crisp line, as
            // Spatial draws its rubber band.
            Rectangle()
                .fill(Self.wash)
                .overlay(Rectangle().strokeBorder(Self.line, lineWidth: 1.5))
                .frame(width: (rect ?? last).width, height: (rect ?? last).height)
                .offset(x: (rect ?? last).minX, y: (rect ?? last).minY)
                .opacity(rect == nil ? 0 : 1)
                // It appears at once and fades when let go.
                .animation(rect == nil ? .easeOut(duration: 0.22) : nil, value: rect == nil)
        }
        .onChange(of: rect) { _, new in if let new { last = new } }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The toast while cards are picked, after the iPhone library's: a rounded
/// bar at the foot of the window with a folder to move the picked cards, a
/// pencil to rename (one card only) and a bin to move them to the Trash.
/// How many are picked shows at the top right. A click anywhere off the
/// toast lets go of them.
struct LibrarySelectionToast: View {
    /// Spatial's desktop bar, measured from its toolbar: about 44 pt
    /// tall with a 14 pt corner, tighter than the iPhone toast's 24.
    static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    let move: () -> Void
    /// Offered when one card is picked.
    let rename: (() -> Void)?
    let trash: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            button(FolderGlyph(), label: "Move to…", action: move)
            if let rename { button(PencilGlyph(), label: "Rename", action: rename) }
            button(TrashGlyph(), label: "Move to Trash", action: trash)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background {
            Self.shape
                .fill(ToastPalette.fill)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        }
        .overlay(Self.shape.strokeBorder(ToastPalette.border, lineWidth: 1))
    }

    private func button(_ glyph: some Shape, label: String, action: @escaping () -> Void) -> some View {
        ToastButton(glyph: AnyShape(glyph), label: label, action: action)
    }
}

private struct ToastButton: View {
    let glyph: AnyShape
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            glyph
                .stroke(ToastPalette.glyph, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                .frame(width: 20, height: 20)
                .frame(width: 40, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.07 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
