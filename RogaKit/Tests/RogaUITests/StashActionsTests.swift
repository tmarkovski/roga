import Foundation
import GitCore
import GitRunner
import MenuUI
import RepositoryEngine
import TestSupport
import Testing
@testable import RogaUI

/// Stashing from the window, and putting back and deleting a stash from its menu
/// (decision 81), against real git, in a clone of the `basic` repository, whose
/// `README.md` is one line.
@Suite(.timeLimit(.minutes(1)))
struct StashActionsTests {
    struct Worktree {
        var model: RepositoryModel
        var path: String
        var branch: BranchModel { model.branch }
    }

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

    func settled(_ work: Worktree) async {
        await work.branch.running?.value
        await work.model.check?.value
        await work.model.load()
        await work.model.selecting?.value
    }

    /// Has the model notice what a test changed behind its back.
    func changedBehindItsBack(_ work: Worktree) async {
        work.model.refsChanged()
        await settled(work)
    }

    func write(_ text: String, to file: String, in work: Worktree) throws {
        try Data(text.utf8).write(to: URL(filePath: work.path + "/" + file))
    }

    func read(_ file: String, in work: Worktree) throws -> String {
        try String(contentsOfFile: work.path + "/" + file, encoding: .utf8)
    }

    func stashes(_ work: Worktree) async throws -> [String] {
        try await git("stash", "list", "--format=%s", in: work.path).split(separator: "\n").map(String.init)
    }

    /// The newest stash, as the refs panel would list it.
    func newestStash(_ work: Worktree) async throws -> StashDetails {
        let commit = try #require(ObjectID(hex: try await git("rev-parse", "stash@{0}", in: work.path)))
        let message = try await git("log", "-1", "--format=%s", commit.hex, in: work.path)
        return StashDetails(position: 0, commit: commit, message: message)
    }

    @Test func stashesEverythingAndShowsTheStashWithUndo() async throws {
        let work = try await worktree()
        try write("mine\n", to: "README.md", in: work)
        try write("new\n", to: "new.txt", in: work)
        await changedBehindItsBack(work)
        #expect(work.model.canStash)

        work.model.stashChanges()
        await settled(work)
        #expect(work.branch.finished == "Stashed 2 files")
        #expect(try await stashes(work) == ["On main: README.md and new.txt"])
        #expect(!work.model.hasWorkingTreeRow)
        #expect(!work.model.canStash)
        // The panels show what went in.
        #expect(work.model.selectedCommit.stash?.commit == (try await newestStash(work)).commit)

        let undo = try #require(work.branch.undoFinished)
        undo.perform()
        await settled(work)
        #expect(work.branch.finished == "Your changes are back")
        #expect(try await stashes(work).isEmpty)
        #expect(try read("README.md", in: work) == "mine\n")
        #expect(try read("new.txt", in: work) == "new\n")
        #expect(work.model.hasWorkingTreeRow)
    }

    @Test func putsAStashBackAndSelectsTheChanges() async throws {
        let work = try await worktree()
        try write("mine\n", to: "README.md", in: work)
        try await git("stash", "push", "--quiet", "--message=Try it", in: work.path)
        await changedBehindItsBack(work)

        work.model.putBack(try await newestStash(work))
        await settled(work)
        #expect(work.branch.finished == "Put back 1 file")
        #expect(try await stashes(work).isEmpty)
        #expect(try read("README.md", in: work) == "mine\n")
        #expect(work.model.selectedRow == 0)
    }

    @Test func deletesAStashWithoutAskingAndUndoListsItAgain() async throws {
        let work = try await worktree()
        try write("mine\n", to: "README.md", in: work)
        try await git("stash", "push", "--quiet", "--message=Try it", in: work.path)
        await changedBehindItsBack(work)
        let stash = try await newestStash(work)
        work.model.select(stash: stash)

        work.model.delete(stash)
        await settled(work)
        #expect(work.branch.finished == "Deleted “Try it”")
        #expect(try await stashes(work).isEmpty)
        // The stash that was showing has gone, so something else shows.
        #expect(work.model.selectedCommit.stash == nil)

        let undo = try #require(work.branch.undoFinished)
        undo.perform()
        await settled(work)
        #expect(try await stashes(work) == ["On main: Try it"])
    }

    @Test func aConflictOpensTheDialogAndUndoTakesItBack() async throws {
        let work = try await worktree()
        let before = try read("README.md", in: work)
        try write("mine\n", to: "README.md", in: work)
        try await git("stash", "push", "--quiet", "--message=Try it", in: work.path)
        try write("theirs\n", to: "README.md", in: work)
        try await git("commit", "--quiet", "-am", "Theirs", in: work.path)
        await changedBehindItsBack(work)
        #expect(before != "theirs\n")

        work.model.putBack(try await newestStash(work))
        await settled(work)
        let conflict = try #require(work.branch.stashConflict)
        #expect(conflict.files == ["README.md"])
        guard case .message(let content) = work.branch.dialog else {
            Issue.record("Expected the dialog for the conflict")
            return
        }
        #expect(content.title == "Putting the stash back stopped on a conflict")
        #expect(content.buttons.map(\.title) == ["Undo", "Resolve"])

        work.branch.undoStashConflict()
        await settled(work)
        #expect(work.branch.stashConflict == nil)
        #expect(try read("README.md", in: work) == "theirs\n")
        #expect(try await stashes(work) == ["On main: Try it"])
        #expect(try await git("status", "--porcelain", in: work.path).isEmpty)
    }

    @Test func theMenuOfTheRowForUncommittedChangesStashesThem() async throws {
        let work = try await worktree()
        try write("mine\n", to: "README.md", in: work)
        await changedBehindItsBack(work)
        let entries = work.model.menuEntries(forRow: 0, badge: nil) { _, _ in }
        let titles = entries.compactMap { entry -> String? in
            if case let .command(title, _, _, _, _) = entry { return title.plain }
            return nil
        }
        #expect(titles == ["Stash changes", "Discard all changes…"])
    }
}
