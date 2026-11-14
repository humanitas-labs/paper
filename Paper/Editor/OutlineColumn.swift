import SwiftUI

/// The outline: the document's headings in a quiet column beside the
/// page, centered in the space right of the text and never over it, under
/// the word "Outline". The first entry's baseline sits on the baseline of
/// the page's first line. The system sans at a small fixed size in neutral
/// steps of the ink, indented by level, with the section in view a step
/// darker and medium. No panel, no rule, no highlight. It narrows when the
/// window leaves too little room past it and hides when even the narrowest
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
    /// Between the text's right edge and the column: at least this, so
    /// the column reads as apart from the page.
    nonisolated static let minimumGap: CGFloat = 56
    /// And at most this, so a very wide window does not strand it.
    nonisolated static let maximumGap: CGFloat = 120
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

    /// The column's width, its gap from the text, and its distance from
    /// the window's right edge, for the room between the text and that
    /// edge; nil to hide. The column takes what width it can up to the
    /// maximum and sits centered in the room, the gap from the text held
    /// to `minimumGap...maximumGap` and at least `minimumTrailing` kept
    /// to the edge.
    nonisolated static func placement(forRoom room: CGFloat) -> (width: CGFloat, gap: CGFloat, trailing: CGFloat)? {
        let width = min(maximumWidth, room - minimumGap - minimumTrailing)
        guard width >= minimumWidth else { return nil }
        let centered = min(max((room - width) / 2, minimumGap), maximumGap)
        let gap = min(centered, room - width - minimumTrailing)
        return (width, gap, room - gap - width)
    }

    /// The label's line height, fixed so the entries start a known
    /// distance below the column's top.
    static var labelHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: labelSize, weight: .semibold)
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// From the column's top to the top of the first entry's text.
    static var entryOffset: CGFloat { labelHeight + labelGap + rowPadding }

    /// Where the first entry's baseline sits, in the window's coordinate
    /// space (SwiftUI's global, top down), reported by the view for the
    /// alignment tests.
    struct FirstEntryBaseline: PreferenceKey {
        static let defaultValue: CGFloat? = nil
        static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
            value = value ?? nextValue()
        }
    }

    /// Each heading's indent, in steps, for the levels in document order:
    /// its rank among the levels the document uses, so a skipped level
    /// takes no room (`#` over `####` indents one step) and the shallowest
    /// level present sits flush left. Capped at `maximumIndentSteps`.
    nonisolated static func indentSteps(for levels: [Int]) -> [Int] {
        let ranks = Dictionary(uniqueKeysWithValues: Set(levels).sorted().enumerated().map { ($1, $0) })
        return levels.map { min(ranks[$0] ?? 0, maximumIndentSteps) }
    }

    var body: some View {
        if let placement = Self.placement(forRoom: model.room), !model.headings.isEmpty {
            GeometryReader { geometry in
                column(placement, height: geometry.size.height)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topTrailing)
            }
        }
    }

    /// The column hung from a hidden line set in the entries' font. That
    /// line's baseline is put `model.firstBaseline` below the top, and the
    /// label and list hang from its top so that the first entry's text
    /// lies exactly over it: the layout system does the arithmetic on the
    /// real text metrics, at any display scale.
    private func column(_ placement: (width: CGFloat, gap: CGFloat, trailing: CGFloat), height: CGFloat) -> some View {
        // Only the list's height needs the ascent, to end `bottom` above
        // the window's edge; a fraction of a point there does not show.
        let ascent = NSFont.systemFont(ofSize: Self.fontSize).ascender
        let top = model.firstBaseline - ascent - Self.entryOffset
        return Text("Outline")
            .font(.system(size: Self.fontSize))
            .lineLimit(1)
            .hidden()
            .frame(width: placement.width, alignment: .leading)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Outline")
                        .font(.system(size: Self.labelSize, weight: .semibold))
                        .foregroundStyle(Color(nsColor: Appearance.outlineInk))
                        .frame(height: Self.labelHeight, alignment: .leading)
                        .padding(.bottom, Self.labelGap)
                        .allowsHitTesting(false)
                    list
                }
                .frame(width: placement.width, height: max(0, height - top - Self.bottom), alignment: .topLeading)
                .alignmentGuide(.top) { _ in Self.entryOffset }
            }
            .padding(.trailing, placement.trailing)
            .alignmentGuide(.top) { dimensions in dimensions[.firstTextBaseline] - model.firstBaseline }
    }

    private var list: some View {
        let headings = model.headings
        let steps = Self.indentSteps(for: headings.map(\.level))
        let rows = ForEach(Array(headings.enumerated()), id: \.element.id) { index, heading in
            row(heading, index: index, steps: steps[index])
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

    private func row(_ heading: OutlineHeading, index: Int, steps: Int) -> some View {
        let isCurrent = model.current == index
        let ink = isCurrent ? Appearance.outlineCurrentInk
            : hovered == heading.id ? Appearance.outlineHoverInk
            : Appearance.outlineInk
        return Text(heading.title)
            .font(.system(size: Self.fontSize, weight: isCurrent ? .medium : .regular))
            .foregroundStyle(Color(nsColor: ink))
            .lineLimit(1)
            .truncationMode(.tail)
            .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                // A zero-height mark on the first entry's baseline.
                if index == 0 {
                    GeometryReader { mark in
                        Color.clear.preference(key: FirstEntryBaseline.self, value: mark.frame(in: .global).minY)
                    }
                    .frame(width: 1, height: 0)
                    .allowsHitTesting(false)
                }
            }
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
