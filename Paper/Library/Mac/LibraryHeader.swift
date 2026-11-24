import AppKit
import SwiftUI

/// The library's header in full screen: back and forward in a capsule,
/// where the window's toolbar shows them otherwise. Nothing lies behind
/// it; the cards scroll up past it to the top.
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
            .background(Capsule().fill(LibraryPalette.background))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
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

/// The folder's name at the head of the library, in a pill of the page's
/// own color: unseen on the bare page, and a clean ground for the name
/// when a card scrolls under it.
struct LibraryTitlePill: View {
    let title: String

    var body: some View {
        Text(title)
            // Set as a folder card's name: regular weight, drawn in a
            // little, in the name's ink.
            .font(.system(size: 14, weight: .regular))
            .tracking(-0.022 * 14)
            .foregroundStyle(FolderCard.nameInk)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(LibraryPalette.background))
            .allowsHitTesting(false)
    }
}
