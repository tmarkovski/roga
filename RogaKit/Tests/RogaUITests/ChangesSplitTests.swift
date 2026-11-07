import Testing
@testable import RogaUI

/// How the panel for uncommitted changes divides its height among the files to
/// stage, the staged files and the commit box.
@Suite
struct ChangesSplitTests {
    @Test func theBoxTakesAFifth() {
        #expect(ChangesSplit.box(in: 800, needs: 146) == 160)
    }

    @Test func theBoxTakesWhatItNeedsWhenAFifthIsTooShort() {
        #expect(ChangesSplit.box(in: 500, needs: 146) == 146)
    }

    @Test func theBoxIsNeverTallerThanThePanel() {
        #expect(ChangesSplit.box(in: 60, needs: 146) == 60)
    }

    @Test func theListsShareTheRestEvenly() {
        // 800 points make 320, 320 and 160, which is 40, 40 and 20.
        #expect(ChangesSplit.filesToStage(in: 640, hasFilesToStage: true, hasStagedFiles: true, emptyListHeight: 36) == 320)
    }

    @Test func nothingStagedLeavesStagedItsHeading() {
        #expect(ChangesSplit.filesToStage(in: 640, hasFilesToStage: true, hasStagedFiles: false, emptyListHeight: 36) == 604)
    }

    @Test func nothingToStageLeavesUnstagedItsHeading() {
        #expect(ChangesSplit.filesToStage(in: 640, hasFilesToStage: false, hasStagedFiles: true, emptyListHeight: 36) == 36)
    }

    @Test func anEmptyHeadingFitsInTheRoomThereIs() {
        #expect(ChangesSplit.filesToStage(in: 20, hasFilesToStage: false, hasStagedFiles: true, emptyListHeight: 36) == 20)
        #expect(ChangesSplit.filesToStage(in: 20, hasFilesToStage: true, hasStagedFiles: false, emptyListHeight: 36) == 0)
    }
}
