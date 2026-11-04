import GitCore
import Testing
@testable import RogaUI

/// What the title row and history say about a worktree that's stuck partway.
@Suite(.timeLimit(.minutes(1)))
struct UnfinishedWorkTests {
    @Test func saysNothingWhenNothingIsUnfinished() {
        #expect(UnfinishedWork(work: nil, conflicts: 0) == nil)
    }

    @Test(arguments: [
        (StoppedWork?.some(.merge), 2, "Merging · 2 conflicts"),
        (.some(.merge), 1, "Merging · 1 conflict"),
        (.some(.merge), 0, "Merging · ready to commit"),
        (.some(.rebase(branch: "refs/heads/tm/fix")), 2, "Rebasing tm/fix · 2 conflicts"),
        (.some(.rebase(branch: "refs/heads/main")), 0, "Rebasing main · ready to continue"),
        (.some(.rebase(branch: nil)), 1, "Rebasing · 1 conflict"),
        (.none, 2, "2 conflicts"),
        (.none, 1, "1 conflict"),
    ] as [(StoppedWork?, Int, String)])
    func saysWhatsUnderwayAndHowFarAlong(work: StoppedWork?, conflicts: Int, title: String) throws {
        let unfinished = try #require(UnfinishedWork(work: work, conflicts: conflicts))
        #expect(unfinished.title == title)
        #expect(unfinished.hasConflicts == (conflicts > 0))
    }
}
