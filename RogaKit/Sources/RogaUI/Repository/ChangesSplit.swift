import SwiftUI

/// How the panel for uncommitted changes divides its height among the files
/// still to stage, the staged files and the commit box. The box takes a fifth,
/// or what it needs if that's more, and the lists share the rest evenly, which
/// makes 40, 40 and 20 while the message is short. That way staging a file
/// doesn't move the line between the lists. A list with no files gets no height,
/// and the other list gets all the room.
nonisolated enum ChangesSplit {
    /// The commit box's share of the panel's height, when it needs no more.
    static let boxShare = 0.2
    /// How the lists and the box get to new heights.
    static let motion = Animation.easeInOut(duration: 0.22)

    /// The commit box's height, from the room under the panel's header and the
    /// least the box needs. It's never taller than the panel, which cuts off
    /// what doesn't fit.
    static func box(in height: Double, needs: Double) -> Double {
        min(height, max(needs, (height * boxShare).rounded()))
    }

    /// The height of the files still to stage, from the room the lists share,
    /// which leaves the staged files the rest.
    static func filesToStage(in height: Double, hasFilesToStage: Bool, hasStagedFiles: Bool) -> Double {
        switch (hasFilesToStage, hasStagedFiles) {
        case (true, true): (height / 2).rounded()
        case (true, false): height
        case (false, _): 0
        }
    }
}

/// Puts the commit box under the lists of files at the height `ChangesSplit`
/// gives it, and the lists over it in the rest.
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

/// Puts the staged files under the files still to stage, at the heights
/// `ChangesSplit` gives them. A list with no files stays here at no height,
/// rather than going away, so that it slides in and out with the line between
/// them.
struct StagedUnderUnstaged: Layout {
    let hasFilesToStage: Bool
    let hasStagedFiles: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let upper = ChangesSplit.filesToStage(in: bounds.height, hasFilesToStage: hasFilesToStage, hasStagedFiles: hasStagedFiles)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: upper))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + upper), proposal: ProposedViewSize(width: bounds.width, height: bounds.height - upper))
    }
}
