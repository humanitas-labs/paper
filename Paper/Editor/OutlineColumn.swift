import SwiftUI

/// The outline: the document's headings in a quiet column at the window's
/// right edge, beside the page and never over it. The body face at a small
/// fixed size in the label ink, indented by level, with the section in
/// view in the full ink. No panel, no rule, no highlight. It narrows with
/// the room beside the text and hides when there is too little, so the
/// text never moves; it does not scale with zoom, as the badges do not.
struct OutlineColumn: View {
    @ObservedObject var model: OutlineModel
    /// Observed so the inks and the face follow theme and config changes.
    @ObservedObject private var store = ConfigurationStore.shared
    @State private var hovered: Int?

    nonisolated static let maximumWidth: CGFloat = 220
    nonisolated static let minimumWidth: CGFloat = 140
    /// From the window's right edge, clearing the 15 pt scroller.
    nonisolated static let trailing: CGFloat = 32
    /// Between the text and the column.
    nonisolated static let gap: CGFloat = 32
    nonisolated static let bottom: CGFloat = 32
    nonisolated static let indentStep: CGFloat = 12
    nonisolated static let maximumIndentSteps = 3
    nonisolated static let fontSize: CGFloat = 13
    nonisolated static let rowPadding: CGFloat = 3

    /// The column's width for the room beside the text, or nil to hide.
    nonisolated static func width(forRoom room: CGFloat) -> CGFloat? {
        let width = min(maximumWidth, room - trailing - gap)
        return width >= minimumWidth ? width : nil
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
        let shallowest = headings.map(\.level).min() ?? 1
        let font = Font(Appearance.bodyFont(size: Self.fontSize))
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(headings.enumerated()), id: \.element.id) { index, heading in
                        row(heading, index: index, shallowest: shallowest, font: font)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: model.current) { _, index in
                guard let index, headings.indices.contains(index) else { return }
                proxy.scrollTo(headings[index].id)
            }
        }
    }

    private func row(_ heading: OutlineHeading, index: Int, shallowest: Int, font: Font) -> some View {
        let lit = model.current == index || hovered == heading.id
        let steps = min(heading.level - shallowest, Self.maximumIndentSteps)
        return Text(heading.title)
            .font(font)
            .foregroundStyle(Color(nsColor: lit ? Appearance.ink : Appearance.labelInk))
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
