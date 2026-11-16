import SwiftUI

/// The view scale, as a percentage, in the window's top-right corner. It
/// shows for a moment whenever the zoom changes, comes back while the
/// pointer rests in that corner, and a click turns it into a field: type a
/// percentage and press Return to set the view to exactly that.
///
/// While the pointer is in the corner a pin sits to the zoom's left: a
/// click pins the document to the menu bar item, as File ▸ Pin Document
/// does, or unpins it. It shows only on hover, never with the flash a
/// zoom change brings, and not for a document that has no file yet.
struct ZoomBadge: View {
    let fileURL: URL?
    @ObservedObject private var zoom = Zoom.observed
    @ObservedObject private var store = ConfigurationStore.shared
    @ObservedObject private var pins = PinStore.shared
    @State private var flashed = false
    @State private var zoneHovering = false
    @State private var pillHovering = false
    @State private var pinHovering = false
    @State private var editing = false
    @State private var visible = false
    @State private var draft = ""
    @State private var hide: Task<Void, Never>?
    @State private var settle: Task<Void, Never>?
    @FocusState private var focused: Bool

    /// The pill, once shown, sits over the zone and takes the hover from
    /// it, so both report; either keeps the pill up, and a short grace
    /// before hiding rides over the hand-off.
    private var wanted: Bool { flashed || hovering || editing }
    private var hovering: Bool { zoneHovering || pillHovering || pinHovering }
    @State private var pinVisible = false
    @State private var pinSettle: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // The hot zone: resting the pointer here brings the badge back.
            Color.clear
                .frame(width: 180, height: 64)
                .contentShape(Rectangle())
                .onHover { zoneHovering = $0 }
            HStack(spacing: 6) {
                if let fileURL {
                    pinButton(fileURL)
                        .onHover { pinHovering = $0 }
                        .opacity(pinVisible ? 1 : 0)
                        .allowsHitTesting(pinVisible)
                        .animation(.easeInOut(duration: 0.18), value: pinVisible)
                }
                pill
                    .onHover { pillHovering = $0 }
            }
            .padding(.top, 14)
            .padding(.trailing, 16)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .animation(.easeInOut(duration: 0.18), value: visible)
        }
        .onChange(of: wanted, initial: true) { _, wanted in
            settle?.cancel()
            if wanted {
                visible = true
            } else {
                settle = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    visible = false
                }
            }
        }
        // The pin follows the hover alone, with the same grace.
        .onChange(of: hovering) { _, hovering in
            pinSettle?.cancel()
            if hovering {
                pinVisible = true
            } else {
                pinSettle = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    pinVisible = false
                }
            }
        }
        .onChange(of: zoom.scale) { _, _ in flash() }
        .onAppear { if zoom.scale != 1 { flash() } }
    }

    private var pill: some View {
        HStack(spacing: 1) {
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 34)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { end() }
                    .onChange(of: focused) { _, isFocused in if !isFocused { end() } }
            } else {
                Text("\(zoom.percent)")
            }
            Text("%")
        }
        .badgePill()
        .pointerStyle(editing ? .default : .link)
        .onTapGesture { if !editing { begin() } }
    }

    /// The pin, filled while the document is pinned. Pinning asks for the
    /// name first; unpinning is one step.
    private func pinButton(_ url: URL) -> some View {
        let pinned = pins.pins.contains(url)
        return Image(systemName: pinned ? "pin.fill" : "pin")
            .badgePill()
            .pointerStyle(.link)
            .help(pinned ? "Unpin Document" : "Pin Document…")
            .accessibilityLabel(pinned ? "Unpin Document" : "Pin Document")
            .accessibilityAddTraits(.isButton)
            .onTapGesture {
                if pins.pins.contains(url) { pins.toggle(url) } else { PinPrompt.pin(url) }
            }
    }

    private func flash() {
        hide?.cancel()
        flashed = true
        hide = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            flashed = false
        }
    }

    private func begin() {
        draft = "\(zoom.percent)"
        editing = true
        focused = true
    }

    private func commit() {
        if let percent = Int(draft.trimmingCharacters(in: .whitespaces)) { Zoom.set(percent: percent) }
        end()
    }

    private func end() {
        editing = false
        focused = false
        flash()
    }
}

extension Zoom.Observed {
    var percent: Int { Int((scale * 100).rounded()) }
}
