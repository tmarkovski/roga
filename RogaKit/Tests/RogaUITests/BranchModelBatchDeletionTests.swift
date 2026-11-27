import Foundation
import GitCore
import RepositoryEngine
import Testing
@testable import RogaUI

/// Deleting a folder of local branches, or the ones picked in the refs panel,
/// from one dialog with a switch for each (decision 121).
extension BranchModelTests {
    /// Asks about deleting local branches by their short names, and waits for
    /// the dialog.
    func askToDelete(_ kind: BranchModel.BranchChoice.Kind, _ names: String..., model: RepositoryModel) async {
        model.branch.askToDelete(branches: names.map { "refs/heads/" + $0 }, as: kind)
        await model.branch.preparingDeletion?.value
    }

    @Test func aFoldersBranchesAllStartOnAndSayWhatOnlyTheyHave() async throws {
        let clones = try await clones()
        _ = try await makeBranchWithACommit("tm/one", clones)
        try await git("branch", "tm/two", "main", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()

        await askToDelete(.folder("tm/"), "tm/one", "tm/two", model: model)
        var dialog = try choiceDialog(model)
        #expect(dialog.title == "Delete the branches in tm/?")
        #expect(dialog.switches.map(\.title.plain) == ["tm/one", "tm/two"])
        #expect(dialog.switches.map(\.isOn) == [true, true])
        #expect(dialog.switches.map(\.detail.plain) == ["1 commit isn't on any other branch or tag.", "Its commits are all on other branches or tags."])
        #expect(dialog.cardsAfterSwitches.first?.first == .heading("This commit would become unreachable", isLost: true))

        try flip(0, model)
        dialog = try choiceDialog(model)
        #expect(dialog.cardsAfterSwitches.first?.first == .heading("1 commit stays on tm/one", isLost: false))
        #expect(dialog.terminal == [.command(["branch", "-D", "tm/two"]), .room(["branch", "-D", "tm/one"])])

        try flip(0, model)
        model.branch.confirmBranchChoice()
        await model.branch.running?.value
        #expect(model.branch.finished == "Deleted 2 branches")
        #expect(try await git("branch", "--list", "tm/*", in: clones.work).isEmpty)
    }

    /// A branch made from another one leads to that one's commits too, so the
    /// dialog counts them only when both go.
    @Test func commitsSharedByPickedBranchesGoOnlyWithAllOfThem() async throws {
        let clones = try await clones()
        _ = try await makeBranchWithACommit("base", clones)
        try await git("switch", "--quiet", "--create", "next", "base", in: clones.work)
        _ = try await commit("Only on next", in: clones.work)
        try await git("switch", "--quiet", "main", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()

        await askToDelete(.picked, "base", "next", model: model)
        var dialog = try choiceDialog(model)
        #expect(dialog.title == "Delete 2 branches?")
        #expect(dialog.switches.map(\.detail.plain) == ["Some of its commits are only on branches in this list.", "1 commit isn't on any other branch or tag."])
        #expect(dialog.cardsAfterSwitches.first?.first == .heading("These 2 commits would become unreachable", isLost: true))

        // next keeps base's commit.
        try flip(1, model)
        dialog = try choiceDialog(model)
        #expect(dialog.cardsAfterSwitches.first?.first == .heading("2 commits stay on next", isLost: false))

        try flip(0, model)
        try flip(1, model)
        dialog = try choiceDialog(model)
        #expect(dialog.cardsAfterSwitches.first?.first == .heading("1 of these 2 commits would become unreachable", isLost: true))
    }

    @Test func aCheckedOutBranchInTheFolderStays() async throws {
        let clones = try await clones()
        try await git("branch", "tm/other", "main", in: clones.work)
        try await git("switch", "--quiet", "--create", "tm/here", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()

        await askToDelete(.folder("tm/"), "tm/here", "tm/other", model: model)
        let dialog = try choiceDialog(model)
        #expect(dialog.switches.map(\.title.plain) == ["tm/other"])
        #expect(dialog.note?.plain == "tm/here is checked out and will be kept.")
    }

    /// The clones' `origin/HEAD` names `main`, so the local `main` is the main
    /// branch, which deleting several branches leaves out.
    @Test func theMainBranchStaysAndTheDialogSaysSo() async throws {
        let clones = try await clones()
        _ = try await makeBranchWithACommit("tm/one", clones)
        try await git("switch", "--quiet", "--create", "tm/here", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()

        await askToDelete(.picked, "main", "tm/one", model: model)
        let dialog = try choiceDialog(model)
        #expect(dialog.title == "Delete 1 branch?")
        #expect(dialog.switches.map(\.title.plain) == ["tm/one"])
        #expect(dialog.note?.plain == "main is the main branch and will be kept.")
    }

    @Test func saysSoWhenOnlyTheMainBranchIsLeft() async throws {
        let clones = try await clones()
        try await git("switch", "--quiet", "--create", "tm/here", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()

        await askToDelete(.picked, "main", "tm/here", model: model)
        #expect(model.branch.branchChoice == nil)
        let failure = try #require(model.branch.failure)
        #expect(failure.title == "Nothing to delete")
        #expect(failure.message == "main is the main branch and will be kept. tm/here is checked out and will be kept.")
    }

    @Test func saysSoWhenEveryBranchIsCheckedOut() async throws {
        let clones = try await clones()
        try await git("switch", "--quiet", "--create", "tm/here", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()

        await askToDelete(.folder("tm/"), "tm/here", model: model)
        #expect(model.branch.branchChoice == nil)
        let failure = try #require(model.branch.failure)
        #expect(failure.title == "Nothing to delete")
        #expect(failure.message == "tm/here is checked out and will be kept.")
    }
}
