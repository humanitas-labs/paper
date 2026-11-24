import AppKit
import SwiftUI

/// The library's header in full screen: back and forward in a capsule,
/// then the folder's name, where the window's toolbar shows them
/// otherwise. It sits on the page's own color, with no band or line.
struct LibraryHeader: View {
    @ObservedObject var navigation: LibraryNavigation

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                arrow("chevron.left", enabled: navigation.canGoBack) { navigation.goBack() }
                Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 16)
                arrow("chevron.right", enabled: navigation.canGoForward) { navigation.goForward() }
            }
            .frame(height: 36)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            Text(navigation.folder.lastPathComponent)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.88))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.primary.opacity(enabled ? 0.8 : 0.3))
                .frame(width: 38, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// What lies behind the library's header, in a window and in full screen:
/// the cards run on under it, blurred and dimmed, and come clear again
/// just below, as under the iPhone's bar.
struct LibraryHeaderShade: View {
    /// The header's height: the window's toolbar, or the drawn header.
    static let height: CGFloat = 52
    /// How far below the header the blur thins out to nothing.
    static let fade: CGFloat = 28

    var body: some View {
        ZStack {
            WindowBlur()
            // Light enough that the cards still show through.
            LibraryPalette.background.opacity(0.3)
        }
        .frame(height: Self.height + Self.fade)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.55),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
    }
}

/// A blur of what lies under it in the same window. SwiftUI's materials
/// blur what is behind the window on the Mac, which leaves the cards
/// under the header sharp or hidden.
private struct WindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.material = .headerView
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
