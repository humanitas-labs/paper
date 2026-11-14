import SwiftUI

/// The outline: the document's headings in a quiet column beside the
/// page, a fixed gap right of the text and never over it, under the word
/// "Outline". The system sans at a small fixed size in neutral steps of
/// the ink, indented by level, with the section in view a step darker and
/// medium. No panel, no rule, no highlight. It narrows when the window
/// leaves too little room past it and hides when even the narrowest
/// column would not fit, so the text never moves; it does not scale with
/// zoom, as the badges do not.
struct OutlineColumn: View {
    @ObservedObject var model: OutlineModel
    /// Observed so the inks and the face follow theme and config changes.
    @ObservedObject private var store = ConfigurationStore.shared
    @State private var hovered: Int?
    /// Off only for offscreen renders: `ImageRenderer` draws nothing
    /// inside a scroll view, so the probes lay the rows out flat.
    var scrolls = true

    nonisolated static let maximumWidth: CGFloat = 220
    nonisolated static let minimumWidth: CGFloat = 140
    /// Between the text's right edge and the column: related to the page,
    /// clearly apart from it.
    nonisolated static let gap: CGFloat = 56
    /// The least room kept between the column and the window's right
    /// edge: 24 pt past the 15 pt scroller.
    nonisolated static let minimumTrailing: CGFloat = 39
    nonisolated static let bottom: CGFloat = 32
    nonisolated static let labelSize: CGFloat = 11
    /// Below the "Outline" label, before the first entry.
    nonisolated static let labelGap: CGFloat = 10
    nonisolated static let indentStep: CGFloat = 12
    nonisolated static let maximumIndentSteps = 3
    nonisolated static let fontSize: CGFloat = 12
    nonisolated static let rowPadding: CGFloat = 4

    /// The column's width and its distance from the window's right edge,
    /// for the room between the text and that edge; nil to hide. The
    /// column starts `gap` past the text and takes what width it can up
    /// to the maximum, keeping at least `minimumTrailing` to the edge.
    nonisolated static func placement(forRoom room: CGFloat) -> (width: CGFloat, trailing: CGFloat)? {
        let width = min(maximumWidth, room - gap - minimumTrailing)
        guard width >= minimumWidth else { return nil }
        return (width, room - gap - width)
    }

    /// The label's line height, so the first entry, not the label, lines
    /// up with the page's first line.
    static var labelHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: labelSize, weight: .semibold)
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// The level drawn flush left: the shallowest level, or, when that
    /// level is a lone document title, the level under it, so the title
    /// and the top sections share the left edge.
    nonisolated static func indentBase(for levels: [Int]) -> Int {
        guard let shallowest = levels.min() else { return 1 }
        let rest = levels.filter { $0 != shallowest }
        guard levels.count - rest.count == 1, let next = rest.min() else { return shallowest }
        return next
    }

    var body: some View {
        if let placement = Self.placement(forRoom: model.room), !model.headings.isEmpty {
            VStack(alignment: .leading, spacing: Self.labelGap) {
                Text("Outline")
                    .font(.system(size: Self.labelSize, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Appearance.outlineInk))
                    .frame(height: Self.labelHeight, alignment: .leading)
                    .allowsHitTesting(false)
                list
            }
            .frame(width: placement.width, alignment: .topLeading)
            .padding(.top, max(0, model.top - Self.labelHeight - Self.labelGap))
            .padding(.trailing, placement.trailing)
            .padding(.bottom, Self.bottom)
        }
    }

    private var list: some View {
        let headings = model.headings
        let shallowest = Self.indentBase(for: headings.map(\.level))
        let rows = ForEach(Array(headings.enumerated()), id: \.element.id) { index, heading in
            row(heading, index: index, shallowest: shallowest)
        }
        return Group {
            if scrolls {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) { rows }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .onChange(of: model.current) { _, index in
                        guard let index, headings.indices.contains(index) else { return }
                        proxy.scrollTo(headings[index].id)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) { rows }
            }
        }
    }

    private func row(_ heading: OutlineHeading, index: Int, shallowest: Int) -> some View {
        let isCurrent = model.current == index
        let ink = isCurrent ? Appearance.outlineCurrentInk
            : hovered == heading.id ? Appearance.outlineHoverInk
            : Appearance.outlineInk
        let steps = min(max(0, heading.level - shallowest), Self.maximumIndentSteps)
        return Text(heading.title)
            .font(.system(size: Self.fontSize, weight: isCurrent ? .medium : .regular))
            .foregroundStyle(Color(nsColor: ink))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, CGFloat(steps) * Self.indentStep)
            .padding(.vertical, Self.rowPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .help(heading.title)
            .pointerStyle(.link)
            .onHover { inside in
                if inside {
                    hovered = heading.id
                } else if hovered == heading.id {
                    hovered = nil
                }
            }
            .onTapGesture { model.jump(to: heading) }
    }
}
