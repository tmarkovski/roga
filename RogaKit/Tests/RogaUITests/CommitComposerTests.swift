import Foundation
import GitCore
import GitRunner
import HistoryUI
import RepositoryEngine
import TestSupport
import Testing
@testable import RogaUI

/// Staging from the panel and committing from the box, against real git.
@Suite(.timeLimit(.minutes(1)))
struct CommitComposerTests {
    struct Worktree {
        var model: RepositoryModel
        var path: String
        var changes: SelectedChanges { model.selectedChanges }
        var composer: CommitComposer { model.composer }
    }

    @discardableResult
    func git(_ arguments: String..., in folder: String) async throws -> String {
        try await TestGit.make().text(GitCommand(arguments, in: folder))
    }

    func worktree(drafts: CommitDrafts = .none) async throws -> Worktree {
        let folder = try makeTemporaryFolder()
        let path = folder + "/work"
        try await git("clone", "--quiet", "--no-local", try await Fixture.repository("basic"), path, in: folder)
        try await git("config", "user.name", "T", in: path)
        try await git("config", "user.email", "t@example.com", in: path)
        return try await worktree(at: path, drafts: drafts)
    }

    func worktree(at path: String, drafts: CommitDrafts = .none) async throws -> Worktree {
        let session = try await RepositorySession.open(containing: path, git: try await TestGit.make())
        let model = RepositoryModel(session: session, worktree: path, fetchesByItself: { false }, drafts: drafts)
        model.branch.timeToPlayHouse = { _ in .zero }
        return Worktree(model: model, path: path)
    }

    func write(_ text: String, to path: String, in repository: String) throws {
        try Data(text.utf8).write(to: URL(filePath: repository + "/" + path))
    }

    func head(_ repository: String) async throws -> String {
        try await git("rev-parse", "HEAD", in: repository)
    }

    /// Loads the worktree with its row for uncommitted changes selected.
    func open(_ work: Worktree) async throws {
        await work.model.appear()
        work.model.selectRow(0)
        await settled(work)
        #expect(work.changes.isSelected)
    }

    /// Lets everything that's been started finish, including the load of history
    /// that a window's view would start after a commit.
    func settled(_ work: Worktree) async {
        await work.changes.applyingIndexChanges?.value
        await work.model.branch.running?.value
        await work.composer.readingMessage?.value
        await work.model.check?.value
        await work.model.load()
        await work.changes.applyingIndexChanges?.value
        await work.changes.loading?.value
        await work.model.selectedCommit.loading?.value
        await work.model.selectedFile.loading?.value
    }

    func paths(_ files: [DiffFile]?) -> [String] {
        (files ?? []).map(\.path)
    }

    // MARK: Staging

    @Test func stagingMovesTheFileAtOnceAndGoesToTheNext() async throws {
        let work = try await worktree()
        try write("changed\n", to: "README.md", in: work.path)
        try write("new one\n", to: "a-new.txt", in: work.path)
        try write("new two\n", to: "b-new.txt", in: work.path)
        try await open(work)
        #expect(work.model.selectedFile.file?.path == "README.md")
        #expect(work.model.selectedFile.group == .unstaged)

        work.changes.toggleSelectedFile()
        // Before git has done anything.
        #expect(paths(work.changes.loaded?.staged) == ["README.md"])
        #expect(paths(work.changes.loaded?.unstaged) == [])
        #expect(work.model.selectedFile.file?.path == "a-new.txt")
        #expect(work.model.selectedFile.group == .untracked)
        #expect(work.model.rowContent(0).subject?.contains("1 staged") == true)

        await settled(work)
        let status = try await work.model.session.status(in: work.path)
        #expect(paths(status.staged) == ["README.md"])
        #expect(work.model.selectedFile.file?.path == "a-new.txt")
    }

    @Test func pressesInARowAllReachTheIndex() async throws {
        let work = try await worktree()
        try write("one\n", to: "a-new.txt", in: work.path)
        try write("two\n", to: "b-new.txt", in: work.path)
        try write("three\n", to: "c-new.txt", in: work.path)
        try await open(work)
        for _ in 0..<3 { work.changes.toggleSelectedFile() }
        await settled(work)
        #expect(paths(try await work.model.session.status(in: work.path).staged) == ["a-new.txt", "b-new.txt", "c-new.txt"])
    }

    @Test func stagingAnotherFileLeavesTheSelectionAlone() async throws {
        let work = try await worktree()
        try write("one\n", to: "a-new.txt", in: work.path)
        try write("two\n", to: "b-new.txt", in: work.path)
        try await open(work)
        let other = try #require(work.changes.loaded?.untracked.last)
        work.changes.toggle(other, in: .untracked)
        #expect(work.model.selectedFile.file?.path == "a-new.txt")
        await settled(work)
        #expect(work.model.selectedFile.file?.path == "a-new.txt")
    }

    @Test func unstagingPutsItBack() async throws {
        let work = try await worktree()
        try write("changed\n", to: "README.md", in: work.path)
        try await git("add", "README.md", in: work.path)
        try await open(work)
        #expect(work.model.selectedFile.group == .staged)
        work.changes.toggleSelectedFile()
        #expect(paths(work.changes.loaded?.unstaged) == ["README.md"])
        await settled(work)
        let status = try await work.model.session.status(in: work.path)
        #expect(status.staged.isEmpty)
        #expect(paths(status.unstaged) == ["README.md"])
    }

    @Test func stageAllTakesWhatTheFilterLeaves() async throws {
        let work = try await worktree()
        try write("one\n", to: "a-new.txt", in: work.path)
        try write("two\n", to: "b-new.txt", in: work.path)
        try await open(work)
        work.model.fileList.filter = "b-"
        work.changes.toggleAll(in: .untracked)
        await settled(work)
        let status = try await work.model.session.status(in: work.path)
        #expect(paths(status.staged) == ["b-new.txt"])
        #expect(paths(status.untracked) == ["a-new.txt"])
    }

    @Test func aFailureSaysWhatGitSaidAndShowsHowThingsAre() async throws {
        let work = try await worktree()
        try write("changed\n", to: "README.md", in: work.path)
        try await open(work)
        FileManager.default.createFile(atPath: work.path + "/.git/index.lock", contents: nil)
        work.changes.toggleSelectedFile()
        #expect(paths(work.changes.loaded?.staged) == ["README.md"])
        await settled(work)
        #expect(work.model.branch.failure?.title == "Can't stage README.md")
        #expect(work.model.branch.failure?.message.contains("index.lock") == true)
        #expect(paths(work.changes.loaded?.staged) == [])
        #expect(paths(work.changes.loaded?.unstaged) == ["README.md"])
    }

    @Test func movingFilesAddsUpTheCountsOfAFileOnBothSides() {
        func file(_ path: String, _ status: DiffFile.Status, _ added: Int, _ removed: Int) -> DiffFile {
            DiffFile(status: status, path: path, oldMode: 0o100644, newMode: 0o100644, lines: .init(added: added, removed: removed))
        }
        let changes = WorktreeChanges(fileCount: 2, unstaged: [file("a", .modified, 1, 2)], staged: [file("a", .modified, 3, 4), file("b", .added, 5, 0)])
        let staged = changes.staging([file("a", .modified, 1, 2)])
        #expect(staged.unstaged.isEmpty)
        #expect(staged.staged.map(\.path) == ["a", "b"])
        #expect(staged.staged.first?.lines == .init(added: 4, removed: 6))

        let back = changes.unstaging([file("b", .added, 5, 0)])
        #expect(back.staged.map(\.path) == ["a"])
        #expect(back.untracked.map(\.path) == ["b"])
        #expect(back.untracked.first?.status == .untracked)
    }

    // MARK: What the button says

    @Test func theButtonSaysWhatItWillDo() async throws {
        let work = try await worktree()
        try write("changed\n", to: "README.md", in: work.path)
        try write("new\n", to: "new.txt", in: work.path)
        try await open(work)
        // With nothing written, it can't run.
        #expect(work.composer.action == .init(title: "Stage All and Commit", isEnabled: false))
        work.composer.message = "   \n"
        #expect(!work.composer.action.isEnabled)
        work.composer.message = "A message"
        #expect(work.composer.action == .init(title: "Stage All and Commit", isEnabled: true))
        work.changes.toggleSelectedFile()
        #expect(work.composer.action.title == "Commit 1 File")
        work.changes.toggleSelectedFile()
        #expect(work.composer.action.title == "Commit 2 Files")
        await settled(work)
    }

    @Test func theHeadingSaysWhereItGoes() async throws {
        let work = try await worktree()
        try write("changed\n", to: "README.md", in: work.path)
        try await open(work)
        #expect(work.composer.heading.lead == "Commit to")
        #expect(work.composer.heading.subject == "main")
        #expect(work.composer.note == nil)
    }

    // MARK: Committing

    @Test func committingLeavesTheRestAndStaysOnTheRow() async throws {
        let work = try await worktree()
        try write("changed\n", to: "README.md", in: work.path)
        try write("new\n", to: "new.txt", in: work.path)
        try await open(work)
        work.changes.toggleSelectedFile()
        work.composer.message = "Change the app\n\nOnly the app."
        work.composer.commit()
        #expect(work.composer.phase == .committing)
        #expect(work.composer.isMessageReadOnly)
        await settled(work)

        #expect(work.composer.phase == .idle)
        #expect(work.composer.message == "")
        #expect(work.changes.isSelected)
        #expect(work.model.selectedRow == 0)
        let log = try await git("log", "-1", "--format=%s%n%b", in: work.path)
        #expect(log.hasPrefix("Change the app\nOnly the app."))
        let status = try await work.model.session.status(in: work.path)
        #expect(status.staged.isEmpty)
        #expect(paths(status.untracked) == ["new.txt"])
        #expect(work.model.branch.finished?.hasPrefix("Committed ") == true)
        #expect(work.model.branch.undoFinished != nil)
        // The new commit is in history, under the row.
        _ = await work.model.loadText(for: 0..<3)
        #expect(work.model.rowContent(1).subject == "Change the app")
    }

    @Test func committingEverythingSelectsTheNewCommit() async throws {
        let work = try await worktree()
        try write("changed\n", to: "README.md", in: work.path)
        try await git("add", "README.md", in: work.path)
        try await open(work)
        work.composer.message = "Change the app"
        work.composer.commit()
        await settled(work)
        #expect(!work.changes.isSelected)
        #expect(!work.model.hasWorkingTreeRow)
        #expect(work.model.selectedCommit.id?.hex == (try await head(work.path)))
        #expect(work.model.selectedRow == 0)
    }

    @Test func withNothingStagedItStagesEverythingFirst() async throws {
        let work = try await worktree()
        try write("changed\n", to: "README.md", in: work.path)
        try write("new\n", to: "new.txt", in: work.path)
        try await open(work)
        work.composer.message = "Everything"
        work.composer.commit()
        await settled(work)
        #expect(try await work.model.session.status(in: work.path).fileCount == 0)
        let files = try await git("show", "--format=", "--name-only", "HEAD", in: work.path)
        #expect(files.split(separator: "\n").sorted() == ["README.md", "new.txt"])
    }

    @Test func aFailedHookKeepsTheMessageAndOffersToSkipIt() async throws {
        let work = try await worktree()
        try write("changed\n", to: "README.md", in: work.path)
        try await git("add", "README.md", in: work.path)
        let hook = work.path + "/.git/hooks/pre-commit"
        try FileManager.default.createDirectory(atPath: work.path + "/.git/hooks", withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho 'line 52 is too long'\nexit 1\n".utf8).write(to: URL(filePath: hook))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        try await open(work)
        let before = try await head(work.path)
        work.composer.message = "Change the app"
        work.composer.commit()
        await settled(work)

        guard case .failed(let output) = work.composer.phase else { throw TestFailure("No failure: \(work.composer.phase)") }
        #expect(output.contains("line 52 is too long"))
        #expect(work.composer.message == "Change the app")
        #expect(work.composer.action.title == "Try Again")
        #expect(work.composer.canSkipHooks)
        // A hook failing is routine, so it shows in the box and not in an alert.
        #expect(work.model.branch.failure == nil)
        #expect(try await head(work.path) == before)

        work.composer.commit(skippingHooks: true)
        await settled(work)
        #expect(work.composer.phase == .idle)
        #expect(try await head(work.path) != before)
    }

    @Test func stoppingACommitThatHangsLeavesTheMessage() async throws {
        let work = try await worktree()
        try write("changed\n", to: "README.md", in: work.path)
        try await git("add", "README.md", in: work.path)
        let hook = work.path + "/.git/hooks/pre-commit"
        try FileManager.default.createDirectory(atPath: work.path + "/.git/hooks", withIntermediateDirectories: true)
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: URL(filePath: hook))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        try await open(work)
        let before = try await head(work.path)
        work.composer.message = "Change the app"
        work.composer.commit()
        try await Task.sleep(for: .milliseconds(300))
        work.composer.stop()
        await settled(work)
        #expect(work.composer.phase == .idle)
        #expect(work.composer.message == "Change the app")
        #expect(try await head(work.path) == before)
    }

    // MARK: Amending

    @Test func amendFillsTheBoxAndUntickingPutsTheDraftBack() async throws {
        let work = try await worktree()
        try write("changed\n", to: "README.md", in: work.path)
        try await open(work)
        let subject = try await git("log", "-1", "--format=%s", in: work.path)
        work.composer.message = "My draft"
        work.composer.setAmending(true)
        await work.composer.readingMessage?.value
        #expect(work.composer.message.hasPrefix(subject))
        #expect(work.composer.heading.lead == "Amend")
        #expect(work.composer.action.title == "Amend Commit")
        work.composer.setAmending(false)
        #expect(work.composer.message == "My draft")
    }

    @Test func amendingReplacesTheCommitAndAnUndoBringsItBack() async throws {
        let work = try await worktree()
        try write("changed\n", to: "README.md", in: work.path)
        try await git("add", "README.md", in: work.path)
        try await open(work)
        let before = try await head(work.path)
        let count = try await git("rev-list", "--count", "HEAD", in: work.path)
        work.composer.setAmending(true)
        await work.composer.readingMessage?.value
        work.composer.message = "A better message"
        work.composer.commit()
        await settled(work)
        #expect(try await git("rev-list", "--count", "HEAD", in: work.path) == count)
        #expect(try await git("log", "-1", "--format=%s", in: work.path) == "A better message")
        #expect(!work.composer.isAmending)
        #expect(work.model.branch.finished?.hasPrefix("Amended ") == true)

        work.composer.undoLastCommit()
        await settled(work)
        #expect(try await head(work.path) == before)
        #expect(work.composer.message == "A better message")
    }

    // MARK: Undoing

    @Test func undoingPutsTheFilesAndTheMessageBackOnTheRow() async throws {
        let work = try await worktree()
        try write("changed\n", to: "README.md", in: work.path)
        try await git("add", "README.md", in: work.path)
        try await open(work)
        let before = try await head(work.path)
        work.composer.message = "Change the app"
        work.composer.commit()
        await settled(work)
        #expect(!work.changes.isSelected)

        work.composer.undoLastCommit()
        await settled(work)
        #expect(try await head(work.path) == before)
        #expect(work.composer.message == "Change the app")
        #expect(work.composer.lastCommit == nil)
        #expect(work.changes.isSelected)
        await settled(work)
        #expect(paths(work.changes.loaded?.staged) == ["README.md"])
    }

    @Test func wontUndoACommitSomethingElseWentOnTopOf() async throws {
        let work = try await worktree()
        try write("changed\n", to: "README.md", in: work.path)
        try await git("add", "README.md", in: work.path)
        try await open(work)
        work.composer.message = "Change the app"
        work.composer.commit()
        await settled(work)
        try await git("commit", "--quiet", "--allow-empty", "-m", "An agent's commit", in: work.path)
        let agents = try await head(work.path)
        work.composer.undoLastCommit()
        await settled(work)
        #expect(try await head(work.path) == agents)
        #expect(work.model.branch.failure?.message.contains("moved HEAD") == true)
    }

    // MARK: Drafts

    @Test func aDraftComesBackInANewModel() async throws {
        final class Store: @unchecked Sendable { var messages: [String: String] = [:] }
        let store = Store()
        let drafts = CommitDrafts { store.messages[$0] ?? "" } write: { store.messages[$0] = $1 }
        let work = try await worktree(drafts: drafts)
        work.composer.message = "Half a thought"
        let again = try await worktree(at: work.path, drafts: drafts)
        #expect(again.composer.message == "Half a thought")

        // Amending shows the commit's own message, which isn't a draft.
        try write("changed\n", to: "README.md", in: work.path)
        try await open(work)
        work.composer.setAmending(true)
        await work.composer.readingMessage?.value
        #expect(store.messages[work.path] == "Half a thought")
    }

    // MARK: Partway through

    /// A merge of a branch that changed the same line, which stops on a conflict.
    func startConflictingMerge(_ work: Worktree) async throws {
        try await git("switch", "--quiet", "-c", "other", in: work.path)
        try write("theirs\n", to: "README.md", in: work.path)
        try await git("commit", "--quiet", "--all", "-m", "Theirs", in: work.path)
        try await git("switch", "--quiet", "-", in: work.path)
        try write("ours\n", to: "README.md", in: work.path)
        try await git("commit", "--quiet", "--all", "-m", "Ours", in: work.path)
        var merge = GitCommand("merge", "other", in: work.path)
        merge.successStatuses = [1]
        _ = try await TestGit.make().run(merge)
    }

    @Test func aMergeOffersItsMessageAndWaitsForItsConflicts() async throws {
        let work = try await worktree()
        try await startConflictingMerge(work)
        try await open(work)
        await work.composer.readingMessage?.value
        #expect(work.composer.stoppedWork == .merge)
        #expect(work.composer.message.hasPrefix("Merge branch 'other'"))
        #expect(!work.composer.message.contains("#"))
        #expect(work.composer.action == .init(title: "1 Conflict Left", isEnabled: false))
        #expect(!work.composer.canAmend)

        let conflict = try #require(work.changes.loaded?.conflicted.first)
        try write("both\n", to: "README.md", in: work.path)
        work.changes.toggle(conflict, in: .conflicted)
        await settled(work)
        #expect(work.composer.action == .init(title: "Commit Merge", isEnabled: true))
        work.composer.commit()
        await settled(work)
        #expect(try await git("rev-list", "--parents", "-1", "HEAD", in: work.path).split(separator: " ").count == 3)
    }

    @Test func anAbortedMergeTakesItsMessageAlong() async throws {
        let work = try await worktree()
        try await startConflictingMerge(work)
        try await open(work)
        await work.composer.readingMessage?.value
        #expect(!work.composer.message.isEmpty)
        try await git("merge", "--abort", in: work.path)
        try write("changed\n", to: "README.md", in: work.path)
        work.model.becameActive()
        await settled(work)
        #expect(work.composer.stoppedWork == nil)
        #expect(work.composer.message == "")
    }

    @Test func aStoppedRebaseShowsItsMessageAndGoesOn() async throws {
        let work = try await worktree()
        try await git("switch", "--quiet", "-c", "base", in: work.path)
        try write("base\n", to: "README.md", in: work.path)
        try await git("commit", "--quiet", "--all", "-m", "Base", in: work.path)
        try await git("switch", "--quiet", "-c", "work", "HEAD~1", in: work.path)
        try write("work\n", to: "README.md", in: work.path)
        try await git("commit", "--quiet", "--all", "-m", "Work on the app", in: work.path)
        var rebase = GitCommand("rebase", "base", in: work.path)
        rebase.successStatuses = [1]
        _ = try await TestGit.make().run(rebase)
        work.composer.message = "My draft"
        try await open(work)
        await work.composer.readingMessage?.value
        #expect(work.composer.shownMessage == "Work on the app")
        #expect(work.composer.isMessageReadOnly)
        #expect(work.composer.action.title == "1 Conflict Left")

        let conflict = try #require(work.changes.loaded?.conflicted.first)
        try write("both\n", to: "README.md", in: work.path)
        work.changes.toggle(conflict, in: .conflicted)
        await settled(work)
        #expect(work.composer.action == .init(title: "Continue Rebase", isEnabled: true))
        work.composer.commit()
        await settled(work)
        #expect(try await work.model.session.stoppedWork(in: work.path) == nil)
        #expect(try await git("log", "-1", "--format=%s", in: work.path) == "Work on the app")
        // What someone was writing is still there.
        #expect(work.composer.message == "My draft")
    }

    // MARK: Pushing

    @Test func commitAndPushPushesWhatItCommitted() async throws {
        let folder = try makeTemporaryFolder()
        let remote = folder + "/remote.git"
        let path = folder + "/work"
        try await git("clone", "--quiet", "--bare", "--no-local", try await Fixture.repository("basic"), remote, in: folder)
        try await git("clone", "--quiet", remote, path, in: folder)
        try await git("config", "user.name", "T", in: path)
        try await git("config", "user.email", "t@example.com", in: path)
        let work = try await worktree(at: path)
        try write("changed\n", to: "README.md", in: path)
        try await open(work)
        await work.model.branch.refresh()
        work.composer.message = "Change and push"
        work.composer.commitAndPush()
        // The push starts once the commit has finished.
        while work.model.branch.finished?.hasPrefix("Pushed") != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        await settled(work)
        #expect(try await git("rev-parse", "main", in: remote) == (try await head(path)))
    }

    struct TestFailure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }
}
