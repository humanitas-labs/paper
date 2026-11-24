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
/// the cards run on under it, out of focus and sinking into the page's
/// own color toward the top, and come clear again just below, as notes
/// do under the iPhone's bar. No tint of its own: a material laid a gray
/// cloud over them.
struct LibraryHeaderShade: View {
    /// The header's height: the window's toolbar, or the drawn header.
    static let height: CGFloat = 52
    /// How far below the header the blur thins out to nothing.
    static let fade: CGFloat = 30

    var body: some View {
        ZStack {
            WindowBlur()
                .mask(LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.6),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
            LinearGradient(
                stops: [
                    .init(color: LibraryPalette.background.opacity(0.82), location: 0),
                    .init(color: LibraryPalette.background.opacity(0.55), location: 0.55),
                    .init(color: LibraryPalette.background.opacity(0), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        .frame(height: Self.height + Self.fade)
        .allowsHitTesting(false)
    }
}

/// A plain blur of what lies under it in the same window, with no tint.
/// SwiftUI's materials blur what is behind the window on the Mac, and
/// AppKit's effect view lays grays of its own over its blur; those are
/// put away here, leaving the blur. Should AppKit build the view some
/// other way one day, the tint simply stays.
private struct WindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = TintlessEffectView()
        view.blendingMode = .withinWindow
        view.material = .hudWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class TintlessEffectView: NSVisualEffectView {
        override func layout() {
            super.layout()
            strip()
        }

        override func updateLayer() {
            super.updateLayer()
            strip()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            DispatchQueue.main.async { [weak self] in self?.strip() }
        }

        private func strip() {
            guard let holder = layer?.sublayers?.first, let parts = holder.sublayers,
                  parts.contains(where: { $0.className.contains("Backdrop") }) else { return }
            for part in parts where !part.className.contains("Backdrop") { part.isHidden = true }
        }
    }
}
