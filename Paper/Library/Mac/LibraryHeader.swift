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
        .background(LibraryPalette.background)
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
