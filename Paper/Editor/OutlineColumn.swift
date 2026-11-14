import SwiftUI

/// The outline: the document's headings in a quiet column at the window's
/// right edge, beside the page and never over it. The system sans at a
/// small fixed size in neutral steps of the ink, indented by level, with
/// the section in view a step darker and medium. No panel, no rule, no
/// highlight. It narrows with
/// the room beside the text and hides when there is too little, so the
/// text never moves; it does not scale with zoom, as the badges do not.
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
    /// From the window's right edge, clearing the 15 pt scroller.
    nonisolated static let trailing: CGFloat = 32
    /// Between the text and the column.
    nonisolated static let gap: CGFloat = 32
    nonisolated static let bottom: CGFloat = 32
    nonisolated static let indentStep: CGFloat = 12
    nonisolated static let maximumIndentSteps = 3
    nonisolated static let fontSize: CGFloat = 12
    nonisolated static let rowPadding: CGFloat = 4

    /// The column's width for the room beside the text, or nil to hide.
    nonisolated static func width(forRoom room: CGFloat) -> CGFloat? {
        let width = min(maximumWidth, room - trailing - gap)
        return width >= minimumWidth ? width : nil
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
        if let width = Self.width(forRoom: model.room), !model.headings.isEmpty {
            list
                .frame(width: width, alignment: .topLeading)
                .padding(.top, model.top)
                .padding(.trailing, Self.trailing)
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
