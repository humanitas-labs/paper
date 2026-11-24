import AppKit
import SwiftUI

/// The welcome window's content: the mark over a greeting, a Get Started
/// list, and the recent documents, set on the theme's canvas in its inks so
/// it reads as a Paper page rather than a system panel. Lists are in the
/// system sans at Zed's sizes; only the greeting is in the serif. Actions
/// leave the window up; it closes itself once a document window opens, so
/// a cancelled Open panel lands back here.
struct WelcomeView: View {
    let recents: [WelcomeModel.Recent]
    /// Folders opened as libraries, newest first.
    var folders: [WelcomeModel.Recent] = []
    let greeting: String
    /// Observed so a theme or font change restyles the open window.
    @ObservedObject private var store = ConfigurationStore.shared
    /// Set once the launch check finds a newer release.
    @ObservedObject private var updates = UpdateCheck.observed

    static let columnWidth: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(maxWidth: .infinity)
                .padding(.bottom, 28)
            section("Get started") {
                row("New file", symbol: "plus", hint: "⌘N") {
                    NSDocumentController.shared.newDocument(nil)
                }
                row("Open…", symbol: "doc", hint: "⌘O") {
                    NSDocumentController.shared.openDocument(nil)
                }
                row("Open folder…", symbol: "folder", hint: "⇧⌘O") {
                    LibraryOpening.chooseFolder()
                }
                row("Settings", symbol: "slider.horizontal.3", hint: "⌘,") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                row("Guide", symbol: "book", hint: "") {
                    Task { await WelcomeDocument.open(replacing: false) }
                }
            }
            if !recents.isEmpty {
                section("Recent") {
                    ForEach(Array(recents.enumerated()), id: \.element.id) { index, recent in
                        row(recent.name, detail: recent.folder, symbol: "doc.text", hint: "⌘\(index + 1)") {
                            NSDocumentController.shared.openDocument(
                                withContentsOf: recent.url, display: true
                            ) { _, _, _ in }
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    }
                }
                .padding(.top, 20)
            }
            if !folders.isEmpty {
                section("Folders") {
                    ForEach(folders) { folder in
                        row(folder.name, detail: folder.folder, symbol: "folder", hint: "") {
                            LibraryOpening.open([folder.url])
                        }
                    }
                }
                .padding(.top, 20)
            }
        }
        .frame(width: Self.columnWidth)
        // Optically centred: a touch above the geometric middle.
        .padding(.bottom, 72)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Appearance.canvas))
        .overlay(alignment: .bottomLeading) {
            if let release = updates.available, updates.justUpdatedTo == nil {
                UpdateBadge(release: release)
            }
        }
        .overlay(alignment: .top) { UpdateToast().ignoresSafeArea(.container, edges: .top) }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image("Enso")
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(Color(nsColor: Appearance.ink))
                .frame(width: 44, height: 44)
            Text(greeting)
                .font(Font(Appearance.font(size: 17, weight: 400, italic: false)))
                .foregroundStyle(Color(nsColor: Appearance.ink))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(title.uppercased())
                    .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                    .tracking(0.3)
                    .foregroundStyle(Color(nsColor: Appearance.labelInk))
                Rectangle()
                    .fill(Color(nsColor: Appearance.thematicBreakInk))
                    .frame(height: 1)
            }
            .padding(.bottom, 6)
            content()
        }
    }

    private func row(
        _ title: String, detail: String? = nil, symbol: String, hint: String, action: @escaping () -> Void
    ) -> some View {
        WelcomeRow(title: title, detail: detail, symbol: symbol, hint: hint, action: action)
    }
}

private struct WelcomeRow: View {
    let title: String
    let detail: String?
    let symbol: String
    let hint: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(Color(nsColor: Appearance.labelInk))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Appearance.ink))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: Appearance.mutedInk))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 16)
                Text(hint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(nsColor: Appearance.mutedInk))
            }
            .padding(.horizontal, 5.5)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: Appearance.hover).opacity(hovering ? 1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The hover wash bleeds past the column so the icon lines up
        // with the section label.
        .padding(.horizontal, -5.5)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
    }
}
