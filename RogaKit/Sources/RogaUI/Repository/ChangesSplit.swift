import SwiftUI

/// How the panel for uncommitted changes divides its height between the files
/// and the commit box. The box takes a fifth, or what it needs if that's more,
/// and the files, which scroll together, get the rest (decision 115).
nonisolated enum ChangesSplit {
    /// The commit box's share of the panel's height, when it needs no more.
    static let boxShare = 0.2
    /// How the box gets to a new height.
    static let motion = Animation.easeInOut(duration: 0.22)

    /// The commit box's height, from the room under the panel's header and the
    /// least the box needs. It's never taller than the panel, which cuts off
    /// what doesn't fit.
    static func box(in height: Double, needs: Double) -> Double {
        min(height, max(needs, (height * boxShare).rounded()))
    }
}

/// Puts the commit box under the files at the height `ChangesSplit` gives it,
/// and the files over it in the rest.
struct BoxUnderLists: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let needs = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
        let box = ChangesSplit.box(in: bounds.height, needs: needs)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height - box))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.maxY - box), proposal: ProposedViewSize(width: bounds.width, height: box))
    }
}
