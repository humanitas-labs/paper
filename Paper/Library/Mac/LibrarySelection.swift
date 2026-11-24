import AppKit
import SwiftUI

/// The rubber band drawn while dragging across the library: a soft fill
/// in the ink's color inside a hairline, as Finder draws one.
struct MarqueeLayer: View {
    /// In the window's content, from its top left; nil when not dragging.
    let rect: CGRect?

    var body: some View {
        GeometryReader { _ in
            if let rect {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.28), lineWidth: 1)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The toast while cards are picked, after the iPhone library's: a rounded
/// bar at the foot of the window with how many are picked, then a folder to
/// move them, a pencil to rename (one card only) and a bin to move them to
/// the Trash. A click anywhere off the toast lets go of them.
struct LibrarySelectionToast: View {
    /// Spatial's desktop bar, measured from its toolbar: about 44 pt
    /// tall with a 14 pt corner, tighter than the iPhone toast's 24.
    static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    let count: Int
    let move: () -> Void
    /// Offered when one card is picked.
    let rename: (() -> Void)?
    let trash: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text(count == 1 ? "1 selected" : "\(count) selected")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ToastPalette.glyph)
                .monospacedDigit()
                .padding(.leading, 12)
                .padding(.trailing, 8)
            button(FolderGlyph(), label: "Move to…", action: move)
            if let rename { button(PencilGlyph(), label: "Rename", action: rename) }
            button(TrashGlyph(), label: "Move to Trash", action: trash)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
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
