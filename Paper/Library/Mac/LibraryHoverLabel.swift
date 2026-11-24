import SwiftUI

/// A name shown on hover, after Spatial's hint labels: the system
/// monospace, spaced out, dark on a pale rounded tablet a shade lighter
/// than the page, with no edge. The name keeps its own case.
struct HoverTarget: Equatable {
    let url: URL
    let text: String
    /// The card's frame in the window's content, from its top left.
    let card: CGRect
}

/// The hovered card's name, centered under the card and kept inside the
/// window: at an edge it slides inward, and a name wider than the window
/// is cut in its middle.
struct HoverLabelLayer: View {
    let target: HoverTarget?
    @State private var labelWidth: CGFloat = 0
    private static let margin: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            if let target {
                let half = labelWidth / 2
                let low = Self.margin + half
                let high = max(low, proxy.size.width - Self.margin - half)
                HoverLabel(text: target.text, maxWidth: max(120, proxy.size.width - 2 * Self.margin))
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { labelWidth = $0 }
                    .position(
                        x: min(max(target.card.midX, low), high),
                        y: target.card.maxY + 12 + HoverLabel.height / 2
                    )
                    .transition(.opacity)
                    .id(target.url)
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.14), value: target?.url)
        .allowsHitTesting(false)
    }
}

private struct HoverLabel: View {
    static let height: CGFloat = 22
    static let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    let text: String
    /// The widest the label may be; a longer name is cut in its middle.
    var maxWidth: CGFloat = .infinity

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .tracking(0.3)
            .foregroundStyle(MenuPalette.ink)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: maxWidth - 18)
            .padding(.horizontal, 9)
            .frame(height: Self.height)
            .background(
                Self.shape
                    .fill(MenuPalette.fill)
                    .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
            )
            .fixedSize()
            .allowsHitTesting(false)
    }
}
