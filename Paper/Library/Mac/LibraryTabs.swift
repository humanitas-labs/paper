import AppKit
import SwiftUI

/// The library window's tabs as one rounded bar of pills at the foot of
/// the window, as in Marina: the tab in front is bright on a lighter
/// pill, the others dim. Each pill shows its number, the key that brings
/// it forward with ⌘, and its folder's name. The plus, shown while the
/// pointer is on the bar, opens a new tab; a middle click closes one.
struct LibraryTabBar: View {
    @ObservedObject var navigation: LibraryNavigation
    @State private var hovering = false
    /// The front tab's highlight is one shape that slides from tab to tab.
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(navigation.tabs.enumerated()), id: \.element.id) { index, tab in
                let inFront = index == navigation.front
                Button { navigation.showTab(index) } label: {
                    HStack(spacing: 5) {
                        if index < 9 {
                            Text("\(index + 1)").foregroundStyle(TabPalette.dim.opacity(inFront ? 0.9 : 0.55))
                        }
                        Text(tab.folder.lastPathComponent)
                            .foregroundStyle(inFront ? TabPalette.text : TabPalette.dim)
                            .lineLimit(1)
                    }
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background {
                        if inFront {
                            Capsule().fill(TabPalette.front).matchedGeometryEffect(id: "front", in: highlight)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .overlay(MiddleClick { navigation.closeTab(index) })
            }
            if hovering {
                Button { navigation.openTab() } label: {
                    Image(systemName: "plus").font(.system(size: 9, weight: .medium)).foregroundStyle(TabPalette.dim)
                        .padding(.horizontal, 9).padding(.vertical, 7).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("New Tab (⌘T)")
                .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
            }
        }
        .animation(.spring(duration: 0.2, bounce: 0.15), value: navigation.front)
        .animation(.spring(duration: 0.28, bounce: 0.15), value: navigation.tabs.count)
        .padding(3)
        .contentShape(Capsule())
        .onHover { inside in withAnimation(.spring(duration: 0.28, bounce: 0.15)) { hovering = inside } }
        .background(Capsule().fill(TabPalette.bar))
        .overlay(Capsule().strokeBorder(TabPalette.border, lineWidth: 1))
    }
}

/// The bar's colors, worked from the library's own so they follow the
/// theme: an opaque bar of the page's color, the front tab a step lifted.
private enum TabPalette {
    static let bar = LibraryPalette.background
    static let front = LibraryPalette.card
    static let border = Color.primary.opacity(0.08)
    static let text = Color.primary
    static let dim = Color.primary.opacity(0.5)
}

/// Catches the middle mouse button over the view it overlays and lets
/// every other click pass through, since SwiftUI has no gesture for it.
struct MiddleClick: NSViewRepresentable {
    let action: () -> Void

    final class Catcher: NSView {
        var action: () -> Void = {}
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .otherMouseDown?, .otherMouseUp?: return super.hitTest(point)
            default: return nil
            }
        }
        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
        }
    }

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.action = action
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) { view.action = action }
}
