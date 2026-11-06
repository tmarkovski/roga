import Foundation
import GitCore
import GitRunner
import HistoryUI
import RepositoryEngine
import TestSupport
import Testing
@testable import RogaUI

/// Reverting a commit from history's menu (decision 44), in a clone of the `basic`
/// repository: `main` has Add the readme, Add the app (`src/app.txt` reads `one`) and
/// Change the app (it reads `one`, `two`), and `feature` adds `NOTES.md` after Add
/// the app.
@Suite(.timeLimit(.minutes(1)))
struct RevertTests {
    struct Worktree {
        var model: RepositoryModel
        var path: String
        var composer: CommitComposer { model.composer }
        var branch: BranchModel { model.branch }
    }

    /// Change the app, on `main`.
    let changeTheApp = ObjectID(hex: Fixture.Basic.main)!
    /// Add notes, on `feature`.
    let addNotes = ObjectID(hex: Fixture.Basic.feature)!

    @discardableResult
    func git(_ arguments: String..., in folder: String) async throws -> String {
        try await TestGit.make().text(GitCommand(arguments, in: folder))
    }

    func worktree() async throws -> Worktree {
        let folder = try makeTemporaryFolder()
        let path = folder + "/work"
        try await git("clone", "--quiet", "--no-local", try await Fixture.repository("basic"), path, in: folder)
        try await git("config", "user.name", "T", in: path)
        try await git("config", "user.email", "t@example.com", in: path)
        let session = try await RepositorySession.open(containing: path, git: try await TestGit.make())
        let model = RepositoryModel(session: session, worktree: path, fetchesByItself: { false }, drafts: .none)
        model.branch.timeToPlayHouse = { _ in .zero }
        model.branch.timeToShowFinished = { _ in .seconds(600) }
        await model.appear()
        return Worktree(model: model, path: path)
    }

    func write(_ text: String, to file: String, in repository: String) throws {
        try Data(text.utf8).write(to: URL(filePath: repository + "/" + file))
    }

    func settled(_ work: Worktree) async {
        await work.model.preparingRevert?.value
        await work.branch.running?.value
        await work.model.check?.value
        await work.composer.readingMessage?.value
        await work.model.load()
        await work.model.selectedChanges.loading?.value
    }

    /// Asks to revert a commit, and returns the dialog that asks how.
    func ask(_ work: Worktree, toRevert commit: ObjectID) async throws -> DialogContent {
        work.model.askToRevert(commit: commit)
        await settled(work)
        guard case .message(let content) = try #require(work.model.dialog) else {
            throw SelectedFileTests.TestError("The dialog isn't a message.")
        }
        #expect(content.id == "revert")
        return content
    }

    func branchDialog(_ work: Worktree) throws -> DialogContent {
        guard case .message(let content) = try #require(work.branch.dialog) else {
            throw SelectedFileTests.TestError("The dialog isn't a message.")
        }
        return content
    }

    func message(of revision: String, in repository: String) async throws -> String {
        try await git("log", "-1", "--format=%B", revision, in: repository).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var gitsMessage: String {
        "Revert \"Change the app\"\n\nThis reverts commit \(Fixture.Basic.main)."
    }

    // MARK: The dialog

    @Test func offersToCommitTheRevertOrLeaveItUncommitted() async throws {
        let work = try await worktree()
        let dialog = try await ask(work, toRevert: changeTheApp)
        #expect(dialog.title == "Revert da9ff973?")
        #expect(dialog.message?.plain == "This undoes what da9ff973 changed, on main.")
        #expect(dialog.cards == [[.commit(hash: "da9ff973", subject: "Change the app")]])
        #expect(dialog.note?.plain == "Leave it uncommitted stages the reversed changes, with git's message ready to commit.")
        #expect(dialog.terminal == [.command(["revert", "--no-edit", Fixture.Basic.main])])
        #expect(dialog.buttons.map(\.title) == ["Cancel", "Leave it uncommitted", "Commit the revert"])
        #expect(dialog.buttons.map(\.kind) == [.secondary, .secondary, .primary])
        #expect(dialog.buttons.allSatisfy { $0.isEnabled && $0.pressesWithReturn })
        #expect(dialog.terminal(pointingAt: 1) == [.command(["revert", "--no-commit", Fixture.Basic.main])])
        #expect(dialog.terminal(pointingAt: 2) == [.command(["revert", "--no-edit", Fixture.Basic.main])])

        dialog.dismiss()
        #expect(work.model.pendingRevert == nil)
    }

    @Test func withSomethingStagedItStartsOnLeavingItUncommitted() async throws {
        let work = try await worktree()
        try write("roga\n", to: "README.md", in: work.path)
        try await git("add", "README.md", in: work.path)
        let dialog = try await ask(work, toRevert: changeTheApp)
        #expect(dialog.message?.plain.hasSuffix("1 file is staged, and git only commits a revert when nothing is, so this adds the reversed changes to it.") == true)
        #expect(dialog.terminal == [.command(["revert", "--no-commit", Fixture.Basic.main])])
        #expect(dialog.buttons.map(\.kind) == [.secondary, .primary, .secondary])
        #expect(dialog.buttons.map(\.isEnabled) == [true, true, false])

        // A press that gets past the disabled button changes nothing.
        work.model.confirmRevert(.committing)
        #expect(work.model.pendingRevert != nil)
    }

    @Test func aMergeSaysWhichSideItKeeps() async throws {
        let work = try await worktree()
        try await git("merge", "--quiet", "--no-ff", "--no-edit", "origin/feature", in: work.path)
        let merge = try #require(ObjectID(hex: try await git("rev-parse", "HEAD", in: work.path)))
        await work.model.load()
        let dialog = try await ask(work, toRevert: merge)
        #expect(dialog.message?.plain.contains("It's a merge, so this keeps the side of its first parent, da9ff973, and takes out what came from b07dd8d5. git still counts those commits as merged, so merging them again won't bring them back.") == true)
        #expect(dialog.terminal == [.command(["revert", "--no-edit", "-m", "1", merge.hex])])
    }

    @Test func aCommitThatHeadDoesntContainTakesAClick() async throws {
        let work = try await worktree()
        let dialog = try await ask(work, toRevert: addNotes)
        #expect(dialog.message?.plain.contains("HEAD doesn't contain b07dd8d5, so git takes its changes out of whatever HEAD has. That only makes sense if they got there another way, such as a cherry-pick.") == true)
        #expect(dialog.buttons.map(\.pressesWithReturn) == [true, false, false])
    }

    @Test func saysWhenGitLeavesOutTheCommitHooks() async throws {
        let work = try await worktree()
        let hook = work.path + "/.git/hooks/pre-commit"
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(filePath: hook))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        let dialog = try await ask(work, toRevert: changeTheApp)
        #expect(dialog.note?.plain.hasSuffix("git commits a revert without your pre-commit and commit-msg hooks, which run when you commit from the box.") == true)
    }

    @Test func canOnlyRevertWhenNothingsUnderway() async throws {
        let work = try await worktree()
        #expect(work.model.canRevert)
        work.branch.unfinished = UnfinishedWork(work: .merge, conflicts: 0)
        #expect(!work.model.canRevert)
        work.model.askToRevert(commit: changeTheApp)
        #expect(work.model.preparingRevert == nil)
    }

    // MARK: Reverting

    @Test func committingSelectsTheRevertAndSaysSo() async throws {
        let work = try await worktree()
        _ = try await ask(work, toRevert: changeTheApp)
        work.model.confirmRevert(.committing)
        #expect(work.model.pendingRevert == nil)
        await settled(work)

        let head = try await git("rev-parse", "HEAD", in: work.path)
        #expect(try await message(of: "HEAD", in: work.path) == gitsMessage)
        #expect(work.model.selectedCommit.id?.hex == head)
        #expect(work.branch.finished == "Reverted da9ff973")
        #expect(work.branch.unfinished == nil)
    }

    @Test func leavingItUncommittedFillsTheBoxWithGitsMessage() async throws {
        let work = try await worktree()
        _ = try await ask(work, toRevert: changeTheApp)
        work.model.confirmRevert(.leavingUncommitted)
        await settled(work)

        #expect(work.model.selectedChanges.isSelected)
        #expect(work.composer.stoppedWork == .revert(commit: changeTheApp))
        #expect(work.composer.message == gitsMessage)
        #expect(work.composer.heading.lead == "Commit revert")
        #expect(work.composer.action == .init(title: "Commit Revert", isEnabled: true))
        #expect(work.branch.unfinished?.title == "Reverting da9ff973 · ready to commit")
        #expect(work.branch.unfinished?.subject == "Change the app")
        #expect(work.model.rowContent(0).subject == "Reverting da9ff973 · 1 uncommitted file, 1 staged")
        #expect(!work.model.canRevert)

        work.composer.commit()
        await settled(work)
        #expect(try await message(of: "HEAD", in: work.path) == gitsMessage)
        #expect(work.composer.stoppedWork == nil)
        #expect(work.branch.unfinished == nil)
    }

    @Test func abortingSaysEverythingStagedGoesBack() async throws {
        let work = try await worktree()
        try write("roga\n", to: "README.md", in: work.path)
        try await git("add", "README.md", in: work.path)
        _ = try await ask(work, toRevert: changeTheApp)
        work.model.confirmRevert(.leavingUncommitted)
        await settled(work)

        work.branch.askToAbort()
        let dialog = try branchDialog(work)
        #expect(dialog.title == "Abort the revert?")
        #expect(dialog.message?.plain == "This takes everything that's staged back to HEAD, in the index and in the files, including anything that was staged before the revert. Any conflicts you've resolved are lost too.")
        #expect(dialog.cards == [[.fact("2 staged files", "go back to HEAD")]])
        #expect(dialog.terminal == [.command(["revert", "--abort"])])
        #expect(dialog.buttons.map(\.kind) == [.secondary, .destructive])

        work.branch.confirmAbort()
        await settled(work)
        #expect(work.branch.unfinished == nil)
        #expect(work.branch.finished == "Aborted the revert")
        #expect(try String(contentsOfFile: work.path + "/README.md", encoding: .utf8) == "yaga\n")
    }

    @Test func aRevertThatStopsOnAConflictAsksWhatToDo() async throws {
        let work = try await worktree()
        try write("one\nTWO\n", to: "src/app.txt", in: work.path)
        try await git("commit", "--quiet", "--all", "--message=Shout two", in: work.path)
        await work.model.load()
        _ = try await ask(work, toRevert: changeTheApp)
        work.model.confirmRevert(.committing)
        await settled(work)

        #expect(work.branch.conflict == BranchModel.Conflict(
            work: .revert(commit: changeTheApp),
            files: ["src/app.txt"],
            ran: ["revert", "--no-edit", Fixture.Basic.main]
        ))
        let dialog = try branchDialog(work)
        #expect(dialog.title == "The revert stopped on a conflict")
        #expect(dialog.message?.plain == "main is partway through a revert, with 1 file in conflict. Roga can't resolve conflicts yet, so you can undo the revert, or leave the worktree as it is and finish from the command line.")
        #expect(dialog.terminal.suffix(2) == [.comment("Undo the revert runs"), .command(["revert", "--abort"])])
        #expect(dialog.buttons.map(\.title) == ["Leave it", "Undo the revert"])
        #expect(dialog.buttons.map(\.kind) == [.secondary, .primary])
        #expect(work.branch.unfinished?.title == "Reverting da9ff973 · 1 conflict")

        work.branch.undoConflict()
        await settled(work)
        #expect(work.branch.unfinished == nil)
        #expect(work.branch.finished == "Undid the revert")
        #expect(try await message(of: "HEAD", in: work.path) == "Shout two")
    }

    @Test func undoingAConflictedRevertThatAddedToStagedFilesSaysTheyGoToo() async throws {
        let work = try await worktree()
        try write("one\nTWO\n", to: "src/app.txt", in: work.path)
        try await git("commit", "--quiet", "--all", "--message=Shout two", in: work.path)
        try write("roga\n", to: "README.md", in: work.path)
        try await git("add", "README.md", in: work.path)
        await work.model.load()
        _ = try await ask(work, toRevert: changeTheApp)
        work.model.confirmRevert(.leavingUncommitted)
        await settled(work)

        #expect(work.branch.conflict?.stagedBefore == 1)
        let dialog = try branchDialog(work)
        #expect(dialog.message?.plain.hasSuffix("Undoing it also takes back the 1 file that was staged before.") == true)
        #expect(dialog.buttons.map(\.kind) == [.secondary, .destructive])
    }

    @Test func saysWhatGitSaidWhenItRefuses() async throws {
        let work = try await worktree()
        // An unstaged change to the file the commit changed, which git won't overwrite.
        try write("one\ntwo\nthree\n", to: "src/app.txt", in: work.path)
        _ = try await ask(work, toRevert: changeTheApp)
        work.model.confirmRevert(.committing)
        await settled(work)

        let failure = try #require(work.branch.failure)
        #expect(failure.title == "Can't revert da9ff973")
        #expect(failure.command == ["revert", "--no-edit", Fixture.Basic.main])
        #expect(failure.changedNothing)
        #expect(failure.message.contains("would be overwritten"))
    }
}
