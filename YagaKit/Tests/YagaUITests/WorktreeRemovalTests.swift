import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import TestSupport
import Testing
@testable import YagaUI

/// Removing a linked worktree from the sidebar, against real git: the list, the
/// way a window goes through asking first, and what it says (decision 22).
@Suite(.timeLimit(.minutes(1)))
struct WorktreeRemovalTests {
    let folder: String
    let store: RepositoryStore

    init() throws {
        folder = try makeTemporaryFolder()
        store = RepositoryStore(file: URL(filePath: folder + "/support/repositories.json"))
    }

    struct Listed {
        var list: RepositoryList
        var repository: ListedRepository
        var main: String
        var linked: String
        var selection: WorktreeSelection
    }

    /// A list with a copy of the `basic` repository, whose linked worktree in the
    /// folder `notes` is on the branch `feature`.
    func listed() async throws -> Listed {
        let main = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        let linked = folder + "/notes"
        try await runGit("worktree", "add", "--quiet", linked, "feature", in: main)
        let list = RepositoryList(store: store)
        await list.connect(git: try await TestGit.make())
        _ = try await list.add(folder: main)
        let repository = try #require(list.repositories.first)
        return Listed(list: list, repository: repository, main: main, linked: linked, selection: WorktreeSelection(repository: repository.path, worktree: linked))
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func start(_ removal: WorktreeRemoval, _ listed: Listed) async throws {
        let worktree = try #require(listed.repository.worktrees.first { $0.path == listed.linked })
        removal.start(worktree, of: listed.repository)
        await removal.running?.value
    }

    // MARK: The list

    @Test func removingALinkedWorktreeTakesItsRowAway() async throws {
        let listed = try await listed()
        try await listed.list.removeWorktree(listed.linked, of: listed.repository, force: false)

        #expect(!exists(listed.linked))
        #expect(listed.repository.worktrees.map(\.path) == [listed.main])
        #expect(listed.repository.removingWorktrees.isEmpty)
        #expect(try await runGit("rev-parse", "--verify", "refs/heads/feature", in: listed.main).count > 0)
    }

    /// `resolve(_:)` is what `WorkspaceView` follows to move a window.
    @Test func aWindowThatShowedItMovesToTheMainWorktree() async throws {
        let listed = try await listed()
        #expect(listed.list.resolve(listed.selection) == listed.selection)

        try await listed.list.removeWorktree(listed.linked, of: listed.repository, force: false)

        #expect(listed.list.resolve(listed.selection) == listed.repository.home)
        #expect(listed.repository.home.worktree == listed.main)
    }

    @Test func forgetsWhatItKnewAboutTheWorktree() async throws {
        let listed = try await listed()
        listed.list.setExpanded(false, listed.repository)
        listed.list.keepShowing(listed.selection)
        listed.list.setUncommittedFiles(4, in: listed.selection)
        listed.list.lastSelection = listed.selection

        try await listed.list.removeWorktree(listed.linked, of: listed.repository, force: false)

        #expect(listed.repository.keptWorktrees.isEmpty)
        #expect(listed.repository.uncommittedFiles[listed.linked] == nil)
        #expect(listed.list.lastSelection == listed.repository.home)
        let reopened = RepositoryList(store: store)
        #expect(reopened.repositories.first?.keptWorktrees.isEmpty == true)
        #expect(reopened.lastSelection == listed.repository.home)
    }

    @Test func leavesOtherSelectionsAlone() async throws {
        let listed = try await listed()
        let home = listed.repository.home
        listed.list.lastSelection = home
        try await listed.list.removeWorktree(listed.linked, of: listed.repository, force: false)
        #expect(listed.list.lastSelection == home)
        #expect(listed.list.resolve(home) == home)
    }

    @Test func theMainWorktreeCantBeRemoved() async throws {
        let listed = try await listed()
        await #expect(throws: GitError.self) {
            try await listed.list.removeWorktree(listed.main, of: listed.repository, force: true)
        }
        #expect(exists(listed.main))
        #expect(listed.repository.worktrees.map(\.path) == [listed.main, listed.linked])
    }

    @Test func aRefusalChangesNothing() async throws {
        let listed = try await listed()
        try "new\n".write(toFile: listed.linked + "/new.txt", atomically: true, encoding: .utf8)
        await #expect(throws: GitError.self) {
            try await listed.list.removeWorktree(listed.linked, of: listed.repository, force: false)
        }
        #expect(exists(listed.linked + "/new.txt"))
        #expect(listed.repository.worktrees.map(\.path) == [listed.main, listed.linked])
        #expect(listed.repository.removingWorktrees.isEmpty)
    }

    /// git has forgotten the worktree by the time it finds it can't delete
    /// everything, so the row shouldn't stay.
    @Test func aFolderGitCouldntFinishDeletingStillLosesItsRow() async throws {
        let listed = try await listed()
        let stuck = listed.linked + "/stuck"
        try FileManager.default.createDirectory(atPath: stuck, withIntermediateDirectories: true)
        try "new\n".write(toFile: stuck + "/file.txt", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stuck)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stuck) }

        await #expect(throws: GitError.self) {
            try await listed.list.removeWorktree(listed.linked, of: listed.repository, force: true)
        }

        #expect(listed.repository.worktrees.map(\.path) == [listed.main])
    }

    // MARK: Going through it in a window

    @Test func asksBeforeRemovingACleanWorktree() async throws {
        let listed = try await listed()
        let removal = WorktreeRemoval()

        try await start(removal, listed)

        let confirmation = try #require(removal.confirmation)
        #expect(confirmation.title == "Remove Worktree feature?")
        #expect(confirmation.buttonTitle == "Remove")
        #expect(exists(listed.linked))

        removal.confirm(confirmation, list: listed.list)
        #expect(removal.confirmation == nil)
        await removal.running?.value

        #expect(!exists(listed.linked))
        #expect(listed.repository.worktrees.map(\.path) == [listed.main])
        #expect(removal.failure == nil)
    }

    @Test func forcesRemovalOnlyAfterSayingSo() async throws {
        let listed = try await listed()
        try "new\n".write(toFile: listed.linked + "/new.txt", atomically: true, encoding: .utf8)
        let removal = WorktreeRemoval()

        try await start(removal, listed)

        let confirmation = try #require(removal.confirmation)
        #expect(confirmation.buttonTitle == "Force Remove")
        #expect(confirmation.message.contains("1 untracked file: new.txt"))
        #expect(exists(listed.linked + "/new.txt"))

        removal.confirm(confirmation, list: listed.list)
        await removal.running?.value

        #expect(!exists(listed.linked))
        #expect(removal.failure == nil)
    }

    /// Deleting a large folder takes minutes, so it can't hold up another one.
    @Test func aRemovalThatsRunningDoesntHoldUpAnother() async throws {
        let listed = try await listed()
        let other = folder + "/other"
        try await runGit("worktree", "add", "--quiet", "-b", "other", other, in: listed.main)
        await listed.list.refresh()
        let removal = WorktreeRemoval()
        try await start(removal, listed)

        removal.confirm(try #require(removal.confirmation), list: listed.list)
        let first = removal.running
        removal.start(try #require(listed.repository.worktrees.first { $0.path == other }), of: listed.repository)
        await first?.value
        await removal.running?.value

        #expect(!exists(listed.linked))
        let second = try #require(removal.confirmation)
        #expect(second.title == "Remove Worktree other?")
        removal.confirm(second, list: listed.list)
        await removal.running?.value
        #expect(!exists(other))
        #expect(listed.repository.worktrees.map(\.path) == [listed.main])
        #expect(removal.failure == nil)
    }

    @Test func cancellingLeavesEverythingAsItWas() async throws {
        let listed = try await listed()
        let removal = WorktreeRemoval()
        try await start(removal, listed)
        #expect(removal.confirmation != nil)
        // What the alert's Cancel button comes to.
        removal.confirmation = nil
        #expect(exists(listed.linked))
        #expect(listed.repository.worktrees.map(\.path) == [listed.main, listed.linked])
    }

    /// Someone can leave the question open while an agent keeps writing, and
    /// what they agreed to is no longer what they'd lose.
    @Test func asksAgainWhenWhatWouldBeLostChanged() async throws {
        let listed = try await listed()
        try "one\n".write(toFile: listed.linked + "/one.txt", atomically: true, encoding: .utf8)
        let removal = WorktreeRemoval()
        try await start(removal, listed)
        let asked = try #require(removal.confirmation)

        try "two\n".write(toFile: listed.linked + "/two.txt", atomically: true, encoding: .utf8)
        removal.confirm(asked, list: listed.list)
        await removal.running?.value

        #expect(exists(listed.linked + "/one.txt"))
        #expect(exists(listed.linked + "/two.txt"))
        let again = try #require(removal.confirmation)
        #expect(again.changed)
        #expect(again.message.hasPrefix("What's in it changed since you were asked."))
        #expect(again.message.contains("2 untracked files: one.txt, two.txt"))

        removal.confirm(again, list: listed.list)
        await removal.running?.value
        #expect(!exists(listed.linked))
    }

    /// A clean worktree that picked up a file is the same case, and must not
    /// turn into forcing it behind the user's back.
    @Test func aCleanWorktreeThatGotChangesAsksToForceFirst() async throws {
        let listed = try await listed()
        let removal = WorktreeRemoval()
        try await start(removal, listed)
        let asked = try #require(removal.confirmation)
        #expect(asked.buttonTitle == "Remove")

        try "new\n".write(toFile: listed.linked + "/new.txt", atomically: true, encoding: .utf8)
        removal.confirm(asked, list: listed.list)
        await removal.running?.value

        #expect(exists(listed.linked + "/new.txt"))
        #expect(removal.confirmation?.buttonTitle == "Force Remove")
    }

    @Test func showsWhatGitSaidAboutALock() async throws {
        let listed = try await listed()
        try await runGit("worktree", "lock", "--reason", "an agent is working", listed.linked, in: listed.main)
        let removal = WorktreeRemoval()

        try await start(removal, listed)
        removal.confirm(try #require(removal.confirmation), list: listed.list)
        await removal.running?.value

        let failure = try #require(removal.failure)
        #expect(failure.title == "Can't Remove Worktree feature")
        #expect(failure.message.contains("an agent is working"))
        #expect(exists(listed.linked))
        #expect(listed.repository.worktrees.map(\.path) == [listed.main, listed.linked])
    }

    @Test func removesAWorktreeWhoseFolderIsGone() async throws {
        let listed = try await listed()
        try FileManager.default.removeItem(atPath: listed.linked)
        await listed.list.refresh()
        #expect(listed.repository.worktrees.last?.isPrunable == true)
        let removal = WorktreeRemoval()

        try await start(removal, listed)
        let confirmation = try #require(removal.confirmation)
        #expect(confirmation.message.contains("is gone already"))
        #expect(confirmation.message.contains("The branch feature stays"))
        #expect(confirmation.buttonTitle == "Remove")

        removal.confirm(confirmation, list: listed.list)
        await removal.running?.value
        #expect(listed.repository.worktrees.map(\.path) == [listed.main])
    }

    // MARK: Deleting the branch too

    /// Adds a linked worktree on a new branch at the main branch's commit, so it
    /// has nothing the main branch doesn't, and starts removing it.
    func startMerged(_ removal: WorktreeRemoval, _ listed: Listed) async throws -> (folder: String, confirmation: WorktreeRemoval.Confirmation) {
        let done = folder + "/done"
        try await runGit("worktree", "add", "--quiet", "-b", "done", done, in: listed.main)
        await listed.list.refresh()
        removal.start(try #require(listed.repository.worktrees.first { $0.path == done }), of: listed.repository)
        await removal.running?.value
        return (done, try #require(removal.confirmation))
    }

    func branchExists(_ name: String, _ listed: Listed) async throws -> Bool {
        try await !runGit("branch", "--list", name, in: listed.main).isEmpty
    }

    @Test func offersToDeleteAMergedBranchToo() async throws {
        let listed = try await listed()
        let removal = WorktreeRemoval()
        let (done, confirmation) = try await startMerged(removal, listed)
        #expect(confirmation.buttonTitleDeletingBranch == "Remove and Delete Branch")
        #expect(confirmation.buttonTitle == "Remove")
        #expect(confirmation.message.hasSuffix("The branch done stays unless you delete it too, which loses nothing, because main has all of its commits."))

        removal.confirm(confirmation, deletingBranch: true, list: listed.list)
        await removal.running?.value

        #expect(!exists(done))
        #expect(try await !branchExists("done", listed))
        #expect(listed.repository.worktrees.map(\.path) == [listed.main, listed.linked])
        #expect(removal.failure == nil)
    }

    @Test func aMergedBranchStaysUnlessDeletingItIsChosen() async throws {
        let listed = try await listed()
        let removal = WorktreeRemoval()
        let (done, confirmation) = try await startMerged(removal, listed)

        removal.confirm(confirmation, list: listed.list)
        await removal.running?.value

        #expect(!exists(done))
        #expect(try await branchExists("done", listed))
    }

    @Test func doesntOfferToDeleteABranchWithCommitsOfItsOwn() async throws {
        let listed = try await listed()
        let removal = WorktreeRemoval()
        try await start(removal, listed)
        let confirmation = try #require(removal.confirmation)
        #expect(confirmation.buttonTitleDeletingBranch == nil)
        #expect(confirmation.message.hasSuffix("The branch feature stays, with its commits."))
    }

    @Test func forcingTheRemovalCanDeleteTheBranchToo() async throws {
        let listed = try await listed()
        let removal = WorktreeRemoval()
        let done = folder + "/done"
        try await runGit("worktree", "add", "--quiet", "-b", "done", done, in: listed.main)
        try "new\n".write(toFile: done + "/new.txt", atomically: true, encoding: .utf8)
        await listed.list.refresh()
        removal.start(try #require(listed.repository.worktrees.first { $0.path == done }), of: listed.repository)
        await removal.running?.value
        let confirmation = try #require(removal.confirmation)
        #expect(confirmation.buttonTitleDeletingBranch == "Force Remove and Delete Branch")

        removal.confirm(confirmation, deletingBranch: true, list: listed.list)
        await removal.running?.value

        #expect(!exists(done))
        #expect(try await !branchExists("done", listed))
    }

    /// The branch was safe to delete when they were asked, and now it has a commit
    /// that only it has.
    @Test func asksAgainWhenAMergedBranchGetsACommit() async throws {
        let listed = try await listed()
        let removal = WorktreeRemoval()
        let (done, confirmation) = try await startMerged(removal, listed)

        try "new\n".write(toFile: done + "/new.txt", atomically: true, encoding: .utf8)
        try await runGit("add", "new.txt", in: done)
        try await runGit("-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "--quiet", "--message=More", in: done)
        removal.confirm(confirmation, deletingBranch: true, list: listed.list)
        await removal.running?.value

        #expect(exists(done))
        #expect(try await branchExists("done", listed))
        let again = try #require(removal.confirmation)
        #expect(again.changed)
        #expect(again.buttonTitleDeletingBranch == nil)
    }

    /// git won't delete a branch that another worktree has checked out, which
    /// takes `--force` to arrange. The worktree has gone by then.
    @Test func saysWhenOnlyTheBranchCouldntGo() async throws {
        let listed = try await listed()
        let removal = WorktreeRemoval()
        let (done, confirmation) = try await startMerged(removal, listed)
        try await runGit("worktree", "add", "--quiet", "--force", folder + "/second", "done", in: listed.main)

        removal.confirm(confirmation, deletingBranch: true, list: listed.list)
        await removal.running?.value

        #expect(!exists(done))
        #expect(!listed.repository.worktrees.contains { $0.path == done })
        #expect(try await branchExists("done", listed))
        let failure = try #require(removal.failure)
        #expect(failure.title == "Can't Delete Branch done")
        #expect(failure.message.hasPrefix("The worktree is gone, and the branch stays."))
    }

    /// It looks again right before deleting, because deleting a large folder can
    /// take minutes.
    @Test func theListKeepsABranchThatIsntMerged() async throws {
        let listed = try await listed()
        do {
            try await listed.list.removeWorktree(listed.linked, of: listed.repository, force: false, deletingBranch: "refs/heads/feature")
            Issue.record("It deleted a branch with commits of its own.")
        } catch RepositoryListError.branchKept(let branch, let message) {
            #expect(branch == "feature")
            #expect(message.contains("main branch"))
        }
        #expect(!exists(listed.linked))
        #expect(listed.repository.worktrees.map(\.path) == [listed.main])
        #expect(try await branchExists("feature", listed))
    }

    // MARK: What it says

    func confirmation(_ losses: WorktreeLosses, branch: String? = "refs/heads/fix", changed: Bool = false) -> WorktreeRemoval.Confirmation {
        WorktreeRemoval.Confirmation(
            repository: "/repo/.git",
            worktree: Worktree(path: "/repo-fix", head: ObjectID(hex: "1234567890123456789012345678901234567890"), branch: branch),
            losses: losses,
            changed: changed
        )
    }

    @Test func namesTheMainBranchThatHasTheCommits() {
        let confirmation = confirmation(WorktreeLosses(branch: "refs/heads/fix", mergedInto: "origin/main"))
        #expect(confirmation.buttonTitleDeletingBranch == "Remove and Delete Branch")
        #expect(confirmation.message.hasSuffix("because origin/main has all of its commits."))
    }

    @Test func saysWhenNothingIsLost() {
        let message = confirmation(WorktreeLosses(branch: "refs/heads/fix")).message
        #expect(message == "This deletes /repo-fix. Everything in it is committed, so nothing is lost.\n\nThe branch fix stays, with its commits.")
    }

    @Test func saysWhatIsLost() {
        let losses = WorktreeLosses(
            branch: "refs/heads/fix",
            changedFiles: ["a.swift"],
            untrackedFiles: ["one", "two", "three", "four", "five"],
            ignored: [".env", "build/"],
            hasSubmodules: true
        )
        #expect(confirmation(losses).message == """
            This deletes /repo-fix, and these can't be brought back:

            • 1 file with uncommitted changes: a.swift
            • 5 untracked files: one, two, three and 2 more
            • 2 ignored items: .env, build/
            • its submodules, with anything uncommitted in them

            The branch fix stays, with its commits.
            """)
    }

    @Test func aDetachedHeadHasNoBranchToKeep() {
        let confirmation = confirmation(WorktreeLosses(detachedCommits: 2, stoppedPull: .rebase), branch: nil)
        #expect(confirmation.title == "Remove Worktree detached at 12345678?")
        #expect(confirmation.buttonTitle == "Remove")
        #expect(confirmation.message == """
            This deletes /repo-fix, and these can't be brought back:

            • 2 commits that only its detached HEAD has
            • a rebase that's partway through
            """)
    }
}
