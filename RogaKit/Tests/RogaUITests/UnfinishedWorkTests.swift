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
        (.some(.revert(commit: ObjectID(hex: "da9ff97390adfc8a4a4b4c0f0a1481c9084145d5"))), 2, "Reverting da9ff973 · 2 conflicts"),
        (.some(.revert(commit: ObjectID(hex: "da9ff97390adfc8a4a4b4c0f0a1481c9084145d5"))), 0, "Reverting da9ff973 · ready to commit"),
        (.some(.revert(commit: nil)), 0, "Reverting · ready to commit"),
        (.none, 2, "2 conflicts"),
        (.none, 1, "1 conflict"),
    ] as [(StoppedWork?, Int, String)])
    func saysWhatsUnderwayAndHowFarAlong(work: StoppedWork?, conflicts: Int, title: String) throws {
        let unfinished = try #require(UnfinishedWork(work: work, conflicts: conflicts))
        #expect(unfinished.title == title)
        #expect(unfinished.hasConflicts == (conflicts > 0))
    }

    @Test func theTooltipNamesTheRevertedCommitAndHowToGoBack() throws {
        let commit = ObjectID(hex: "da9ff97390adfc8a4a4b4c0f0a1481c9084145d5")
        let unfinished = try #require(UnfinishedWork(work: .revert(commit: commit), conflicts: 0, subject: "Change the app"))
        #expect(unfinished.help == "Reverting da9ff973 · ready to commit\n\u{201C}Change the app\u{201D}\nYou can finish from the command line, or git revert --abort goes back.")
        #expect(try #require(UnfinishedWork(work: nil, conflicts: 2)).help == "2 conflicts")
    }

    @Test func abortingARevertHasItsOwnWords() {
        let work = StoppedWork.revert(commit: nil)
        #expect(work.abortTitle == "Abort Revert…")
        #expect(work.abortedNote == "Aborted the revert")
        #expect(work.abortArguments == ["revert", "--abort"])
        #expect(work.leavesAMessage)
        #expect(!StoppedWork.rebase(branch: nil).leavesAMessage)
    }
}
