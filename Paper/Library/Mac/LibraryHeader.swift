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

/// The folder's name at the head of the library, with a folder before it.
/// Under the pointer a copy glyph shows after the name; a click copies
/// the folder's path, and the glyph is a check for a moment.
struct LibraryFolderTitle: View {
    let folder: URL
    @State private var hovering: Bool
    @State private var copied = false

    /// `hovering` is true only for an offscreen render of the hover.
    init(folder: URL, hovering: Bool = false) {
        self.folder = folder
        _hovering = State(initialValue: hovering)
    }

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 6) {
                FolderGlyph()
                    .stroke(FolderCard.nameInk.opacity(0.75), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    .frame(width: 16, height: 16)
                Text(folder.lastPathComponent)
                    .font(.system(size: 14, weight: .regular))
                    .tracking(-0.022 * 14)
                    .foregroundStyle(FolderCard.nameInk)
                    .lineLimit(1)
                // Only there under the pointer: kept in place and unseen,
                // it left the pill a glyph's width too long after the name.
                if hovering || copied {
                    ZStack {
                        if copied {
                            CheckGlyph().stroke(FolderCard.nameInk.opacity(0.75), style: Self.stroke).transition(.opacity)
                        } else {
                            CopyGlyph().stroke(FolderCard.nameInk.opacity(0.6), style: Self.stroke).transition(.opacity)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(LibraryPalette.background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: copied)
        .help("Copy Path")
        .accessibilityLabel("\(folder.lastPathComponent), copy path")
        // A new folder's name does not inherit the last one's check.
        .onChange(of: folder) { copied = false }
    }

    private static let stroke = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)

    private func copy() {
        DocumentPath.copy(folder)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}
