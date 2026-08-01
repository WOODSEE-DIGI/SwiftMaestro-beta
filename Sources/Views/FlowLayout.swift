import SwiftUI

/// A simple left-to-right, top-to-bottom flow layout that wraps its subviews
/// onto as many rows as needed to fit the available width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat? = nil

    private var effectiveRowSpacing: CGFloat { rowSpacing ?? spacing }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let result = FlowResult(
            in: proposal.width ?? .infinity,
            subviews: subviews,
            spacing: spacing,
            rowSpacing: effectiveRowSpacing
        )
        return result.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing,
            rowSpacing: effectiveRowSpacing
        )
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + result.positions[index].x,
                    y: bounds.minY + result.positions[index].y
                ),
                proposal: .unspecified
            )
        }
    }

    private struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(
            in maxWidth: CGFloat,
            subviews: Subviews,
            spacing: CGFloat,
            rowSpacing: CGFloat
        ) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth, x > 0 {
                    x = 0
                    y += rowHeight + rowSpacing
                    rowHeight = 0
                }
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
            }

            let width = maxWidth == .infinity ? max(0, x - spacing) : maxWidth
            self.size = CGSize(width: width, height: y + rowHeight)
        }
    }
}
