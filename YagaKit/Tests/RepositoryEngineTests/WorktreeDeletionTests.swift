import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Deleting linked worktrees, in a clone of a bare copy of the `basic` repository.
/// The clone has a linked worktree on `topic`, which has no commits of its own yet.
@Suite(.timeLimit(.minutes(1)))
struct WorktreeDeletionTests {
    struct Clone {
        var folder: String
        var remote: String
        var work: String
        /// The linked worktree's folder.
        var linked: String
        var session: RepositorySession
    }

    func clone() async throws -> Clone {
        let fixture = try await Fixture.repository("basic")
        let folder = try makeTemporaryFolder()
        let remote = folder + "/remote.git"
        let work = folder + "/work"
        let linked = folder + "/linked"
        try await runGit("clone", "--quiet", "--bare", "--no-local", fixture, remote, in: fixture)
        try await runGit("clone", "--quiet", remote, work, in: folder)
        try await runGit("worktree", "add", "--quiet", "-b", "topic", linked, "main", in: work)
        let session = try await RepositorySession.open(containing: work, git: try await TestGit.make())
        return Clone(folder: folder, remote: remote, work: work, linked: linked, session: session)
    }

    @discardableResult
    func commit(_ message: String, in folder: String) async throws -> String {
        try await runGit("-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "--quiet", "--allow-empty", "-m", message, in: folder)
        return try await runGit("rev-parse", "HEAD", in: folder)
    }

    /// Pushes `topic`, so that it tracks `origin/topic`.
    func push(in clone: Clone) async throws {
        try await runGit("push", "--quiet", "--set-upstream", "origin", "topic", in: clone.linked)
    }

    func exists(_ ref: String, in folder: String) async throws -> Bool {
        try await !runGit("for-each-ref", "--format=%(refname)", ref, in: folder).isEmpty
    }

    func isListed(_ clone: Clone) async throws -> Bool {
        try await clone.session.worktrees().contains { $0.path == clone.linked }
    }

    func folderExists(_ clone: Clone) -> Bool {
        FileManager.default.fileExists(atPath: clone.linked)
    }

    func prepare(_ scope: WorktreeDeletion.Scope, in clone: Clone, limit: Int = 5) async throws -> WorktreeDeletion {
        try await clone.session.prepareToDelete(worktree: clone.linked, limit: limit).deletion(for: scope)
    }

    // MARK: The worktree alone

    @Test func deletesACleanWorktreeWithoutAskingAndKeepsItsBranch() async throws {
        let clone = try await clone()
        let deletion = try await prepare(.worktree, in: clone)
        #expect(!deletion.asksFirst)
        #expect(deletion.branch == nil)
        #expect(deletion.remoteBranch == nil)
        #expect(deletion.removeArguments == ["worktree", "remove", clone.linked])

        try await clone.session.delete(deletion)
        #expect(!folderExists(clone))
        #expect(try await !isListed(clone))
        #expect(try await exists("refs/heads/topic", in: clone.work))
    }

    @Test func aBranchKeepsItsCommitsWhenOnlyTheWorktreeGoes() async throws {
        let clone = try await clone()
        try await commit("On topic", in: clone.linked)
        let deletion = try await prepare(.worktree, in: clone)
        #expect(deletion.lostCount == 0)
        #expect(!deletion.asksFirst)
    }

    @Test func asksAboutUncommittedFilesAndForcesTheirRemoval() async throws {
        let clone = try await clone()
        try "new".write(toFile: clone.linked + "/untracked.txt", atomically: true, encoding: .utf8)
        try "changed".write(toFile: clone.linked + "/README.md", atomically: true, encoding: .utf8)
        let deletion = try await prepare(.worktree, in: clone)
        #expect(deletion.uncommittedFiles == 2)
        #expect(deletion.asksFirst)
        #expect(deletion.removeArguments == ["worktree", "remove", "--force", clone.linked])

        try await clone.session.delete(deletion)
        #expect(!folderExists(clone))
    }

    @Test func countsUntrackedFilesEvenWhenTheyreTurnedOff() async throws {
        let clone = try await clone()
        try await runGit("config", "status.showUntrackedFiles", "no", in: clone.work)
        try "new".write(toFile: clone.linked + "/untracked.txt", atomically: true, encoding: .utf8)
        let deletion = try await prepare(.worktree, in: clone)
        #expect(deletion.uncommittedFiles == 1)
        #expect(deletion.asksFirst)
    }

    @Test func gitRefusesFilesThatAppearedAfterAsking() async throws {
        let clone = try await clone()
        let deletion = try await prepare(.worktree, in: clone)
        try "new".write(toFile: clone.linked + "/untracked.txt", atomically: true, encoding: .utf8)
        await #expect(throws: GitError.self) {
            try await clone.session.delete(deletion)
        }
        #expect(FileManager.default.fileExists(atPath: clone.linked + "/untracked.txt"))
    }

    @Test func asksAboutIgnoredFilesWithoutGoingThroughIgnoredFolders() async throws {
        let clone = try await clone()
        let exclude = try await runGit("rev-parse", "--path-format=absolute", "--git-common-dir", in: clone.work) + "/info/exclude"
        try ".env\nbuild/\n".write(toFile: exclude, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: clone.linked + "/build/deep", withIntermediateDirectories: true)
        try "x".write(toFile: clone.linked + "/build/deep/one.o", atomically: true, encoding: .utf8)
        try "x".write(toFile: clone.linked + "/build/deep/two.o", atomically: true, encoding: .utf8)
        try "SECRET=1".write(toFile: clone.linked + "/.env", atomically: true, encoding: .utf8)

        let deletion = try await prepare(.worktree, in: clone)
        #expect(deletion.uncommittedFiles == 0)
        #expect(deletion.ignored == [".env", "build/"])
        #expect(deletion.ignoredCount == 2)
        #expect(deletion.asksFirst)
        // git doesn't need forcing for ignored files.
        #expect(deletion.removeArguments == ["worktree", "remove", clone.linked])

        try await clone.session.delete(deletion)
        #expect(!folderExists(clone))
    }

    @Test func listsOnlyTheFirstIgnoredFiles() async throws {
        let clone = try await clone()
        let exclude = try await runGit("rev-parse", "--path-format=absolute", "--git-common-dir", in: clone.work) + "/info/exclude"
        try "*.log\n".write(toFile: exclude, atomically: true, encoding: .utf8)
        for name in ["a", "b", "c"] { try "x".write(toFile: clone.linked + "/\(name).log", atomically: true, encoding: .utf8) }
        let deletion = try await prepare(.worktree, in: clone, limit: 2)
        #expect(deletion.ignored == ["a.log", "b.log"])
        #expect(deletion.ignoredCount == 3)
    }

    // MARK: A detached HEAD

    @Test func countsCommitsOnlyADetachedHeadLeadsTo() async throws {
        let clone = try await clone()
        try await runGit("switch", "--quiet", "--detach", in: clone.linked)
        let first = try await commit("Detached one", in: clone.linked)
        let second = try await commit("Detached two", in: clone.linked)

        let deletion = try await prepare(.worktree, in: clone)
        #expect(deletion.branch == nil)
        #expect(deletion.lostCount == 2)
        #expect(deletion.lost.map(\.hex) == [second, first])
        #expect(deletion.asksFirst)
    }

    @Test func aDetachedHeadOnABranchLosesNothing() async throws {
        let clone = try await clone()
        try await runGit("switch", "--quiet", "--detach", "main", in: clone.linked)
        let deletion = try await prepare(.worktree, in: clone)
        #expect(deletion.lostCount == 0)
        #expect(!deletion.asksFirst)
    }

    @Test func anotherWorktreesHeadKeepsCommits() async throws {
        let clone = try await clone()
        try await runGit("switch", "--quiet", "--detach", in: clone.linked)
        let tip = try await commit("Shared", in: clone.linked)
        try await runGit("worktree", "add", "--quiet", "--detach", clone.folder + "/other", tip, in: clone.work)
        let deletion = try await prepare(.worktree, in: clone)
        #expect(deletion.lostCount == 0)
    }

    // MARK: Submodules

    /// Commits a submodule on `topic`, checked out in the linked worktree, which
    /// leaves the worktree clean. git needs telling to allow a URL that's a folder.
    func addSubmodule(_ path: String = "vendor/lib", in clone: Clone) async throws {
        try await runGit("-c", "protocol.file.allow=always", "submodule", "add", "--quiet", clone.remote, path, in: clone.linked)
        try await commit("Add \(path)", in: clone.linked)
    }

    @Test func gitRefusesACleanWorktreeWithASubmoduleUnlessItsForced() async throws {
        let clone = try await clone()
        try await addSubmodule(in: clone)
        await #expect(throws: (any Error).self) {
            try await runGit("worktree", "remove", clone.linked, in: clone.work)
        }
        #expect(folderExists(clone))
    }

    @Test func asksAboutASubmoduleAndForcesItsRemoval() async throws {
        let clone = try await clone()
        try await addSubmodule(in: clone)
        let deletion = try await prepare(.worktree, in: clone)
        #expect(deletion.uncommittedFiles == 0)
        #expect(deletion.hasSubmodules)
        #expect(deletion.submoduleCount == 1)
        #expect(deletion.submodules == ["vendor/lib"])
        #expect(deletion.asksFirst)
        #expect(deletion.removeArguments == ["worktree", "remove", "--force", clone.linked])

        try await clone.session.delete(deletion)
        #expect(!folderExists(clone))
        #expect(try await !isListed(clone))
    }

    @Test func listsOnlyTheFirstSubmodules() async throws {
        let clone = try await clone()
        for name in ["a", "b", "c"] { try await addSubmodule("vendor/\(name)", in: clone) }
        let deletion = try await prepare(.worktree, in: clone, limit: 2)
        #expect(deletion.submodules == ["vendor/a", "vendor/b"])
        #expect(deletion.submoduleCount == 3)
    }

    @Test func aSubmoduleThatWasNeverCheckedOutNeedsNoForce() async throws {
        let clone = try await clone()
        try await addSubmodule(in: clone)
        let other = clone.folder + "/other"
        try await runGit("worktree", "add", "--quiet", "--detach", other, "topic", in: clone.work)
        let deletion = try await clone.session.prepareToDelete(worktree: other, limit: 5).deletion(for: .worktree)
        #expect(!deletion.hasSubmodules)
        #expect(deletion.submodules.isEmpty)
        #expect(!deletion.asksFirst)
        #expect(deletion.removeArguments == ["worktree", "remove", other])

        try await clone.session.delete(deletion)
        #expect(!FileManager.default.fileExists(atPath: other))
    }

    @Test func aSubmoduleThatWasDeinitializedStillNeedsForce() async throws {
        let clone = try await clone()
        try await addSubmodule(in: clone)
        try await runGit("submodule", "deinit", "--quiet", "--all", in: clone.linked)
        let deletion = try await prepare(.worktree, in: clone)
        #expect(deletion.hasSubmodules)
        #expect(deletion.submoduleCount == 0)
        #expect(deletion.asksFirst)
        #expect(deletion.removeArguments == ["worktree", "remove", "--force", clone.linked])

        try await clone.session.delete(deletion)
        #expect(!folderExists(clone))
    }

    @Test func aLockedWorktreeWithASubmoduleIsStillRefused() async throws {
        let clone = try await clone()
        try await addSubmodule(in: clone)
        try await runGit("worktree", "lock", "--reason", "agent running", clone.linked, in: clone.work)
        let deletion = try await prepare(.worktree, in: clone)
        #expect(deletion.isRefused)
        #expect(!deletion.asksFirst)

        let error = await #expect(throws: GitError.self) {
            try await clone.session.delete(deletion)
        }
        #expect(error?.message.contains("agent running") == true)
        #expect(folderExists(clone))
    }

    @Test func aWorktreeWithASubmoduleWhoseFolderIsMissingNeedsNoForce() async throws {
        let clone = try await clone()
        try await addSubmodule(in: clone)
        try FileManager.default.removeItem(atPath: clone.linked)
        let deletion = try await prepare(.worktree, in: clone)
        #expect(!deletion.hasSubmodules)
        #expect(!deletion.asksFirst)

        try await clone.session.delete(deletion)
        #expect(try await !isListed(clone))
    }

    // MARK: The branch too

    @Test func deletesTheBranchOfACleanWorktreeWithoutAskingWhenItLosesNothing() async throws {
        let clone = try await clone()
        let deletion = try await prepare(.worktreeAndBranch, in: clone)
        #expect(deletion.branch?.ref == "refs/heads/topic")
        #expect(deletion.lostCount == 0)
        #expect(!deletion.asksFirst)

        try await clone.session.delete(deletion)
        #expect(!folderExists(clone))
        #expect(try await !exists("refs/heads/topic", in: clone.work))
    }

    @Test func countsTheCommitsOfAnUnmergedBranchDespiteItsOwnHead() async throws {
        let clone = try await clone()
        let first = try await commit("Unmerged one", in: clone.linked)
        let second = try await commit("Unmerged two", in: clone.linked)
        let deletion = try await prepare(.worktreeAndBranch, in: clone)
        #expect(deletion.lostCount == 2)
        #expect(deletion.lost.map(\.hex) == [second, first])
        #expect(deletion.asksFirst)

        try await clone.session.delete(deletion)
        #expect(try await !exists("refs/heads/topic", in: clone.work))
    }

    @Test func aPushedBranchLosesNothingAndItsRemoteBranchStays() async throws {
        let clone = try await clone()
        try await commit("Pushed", in: clone.linked)
        try await push(in: clone)
        let deletion = try await prepare(.worktreeAndBranch, in: clone)
        #expect(deletion.lostCount == 0)
        #expect(deletion.remoteBranch == nil)
        #expect(!deletion.asksFirst)

        try await clone.session.delete(deletion)
        #expect(try await !exists("refs/heads/topic", in: clone.work))
        #expect(try await exists("refs/remotes/origin/topic", in: clone.work))
        #expect(try await exists("refs/heads/topic", in: clone.remote))
    }

    @Test func aBranchWithoutCommitsHasNothingToDelete() async throws {
        let clone = try await clone()
        try await runGit("worktree", "add", "--quiet", "--orphan", "-b", "empty", clone.folder + "/empty", in: clone.work)
        let deletion = try await clone.session.prepareToDelete(worktree: clone.folder + "/empty", limit: 5).deletion(for: .worktreeAndBranch)
        #expect(deletion.branch == nil)
        #expect(deletion.lostCount == 0)

        try await clone.session.delete(deletion)
        #expect(!FileManager.default.fileExists(atPath: clone.folder + "/empty"))
    }

    // MARK: Everything

    @Test func deletesEverythingAfterAsking() async throws {
        let clone = try await clone()
        try await commit("Pushed", in: clone.linked)
        try await push(in: clone)
        let deletion = try await prepare(.everything, in: clone)
        #expect(deletion.asksFirst)
        #expect(deletion.commands == [
            ["worktree", "remove", clone.linked],
            ["branch", "-D", "topic"],
            ["push", "--delete", "origin", "refs/heads/topic"],
        ])
        // Nothing else has this commit, so it goes for everyone.
        #expect(deletion.lostCount == 1)

        try await clone.session.delete(deletion)
        #expect(!folderExists(clone))
        #expect(try await !isListed(clone))
        #expect(try await !exists("refs/heads/topic", in: clone.work))
        #expect(try await !exists("refs/remotes/origin/topic", in: clone.work))
        #expect(try await !exists("refs/heads/topic", in: clone.remote))
    }

    @Test func countsCommitsOnlyTheRemoteBranchHas() async throws {
        let clone = try await clone()
        try await push(in: clone)
        try await runGit("clone", "--quiet", "--branch", "topic", clone.remote, clone.folder + "/other", in: clone.folder)
        let theirs = try await commit("Theirs", in: clone.folder + "/other")
        try await runGit("push", "--quiet", in: clone.folder + "/other")
        try await runGit("fetch", "--quiet", "origin", in: clone.work)

        let deletion = try await prepare(.everything, in: clone)
        #expect(deletion.lostCount == 1)
        #expect(deletion.lost.map(\.hex) == [theirs])
    }

    @Test func usesTheNameTheRemoteHasForTheBranch() async throws {
        let clone = try await clone()
        try await runGit("push", "--quiet", "--set-upstream", "origin", "topic:renamed", in: clone.linked)
        let deletion = try await prepare(.everything, in: clone)
        #expect(deletion.remoteBranch?.ref == "refs/remotes/origin/renamed")
        #expect(deletion.remoteBranch?.place == .remote("origin", branch: "renamed"))

        try await clone.session.delete(deletion)
        #expect(try await !exists("refs/heads/renamed", in: clone.remote))
    }

    @Test func aBranchWithoutAnUpstreamHasNoRemoteStep() async throws {
        let clone = try await clone()
        let deletion = try await prepare(.everything, in: clone)
        #expect(deletion.remoteBranch == nil)
        #expect(!deletion.asksFirst)
    }

    @Test func aPrunedUpstreamHasNoRemoteStep() async throws {
        let clone = try await clone()
        try await push(in: clone)
        try await runGit("update-ref", "-d", "refs/remotes/origin/topic", in: clone.work)
        let deletion = try await prepare(.everything, in: clone)
        #expect(deletion.remoteBranch == nil)
    }

    @Test func anotherLocalBranchAsUpstreamIsLeftAlone() async throws {
        let clone = try await clone()
        try await runGit("branch", "--set-upstream-to=main", "topic", in: clone.work)
        let deletion = try await prepare(.everything, in: clone)
        #expect(deletion.remoteBranch == nil)

        try await clone.session.delete(deletion)
        #expect(try await exists("refs/heads/main", in: clone.work))
    }

    @Test func removesOurCopyWhenTheRemoteBranchIsAlreadyGone() async throws {
        let clone = try await clone()
        try await push(in: clone)
        try await runGit("branch", "--quiet", "-D", "topic", in: clone.remote)
        let deletion = try await prepare(.everything, in: clone)
        #expect(deletion.remoteBranch != nil)

        try await clone.session.delete(deletion)
        #expect(try await !exists("refs/remotes/origin/topic", in: clone.work))
        #expect(try await !exists("refs/heads/topic", in: clone.work))
    }

    // MARK: Choosing

    @Test func knowsTheRemoteBranchItsBranchTracks() async throws {
        let clone = try await clone()
        var choice = try await clone.session.prepareToDelete(worktree: clone.linked, limit: 5)
        #expect(choice.branch?.ref == "refs/heads/topic")
        #expect(choice.remoteBranch == nil)
        #expect(choice.widest == .worktreeAndBranch)

        try await push(in: clone)
        choice = try await clone.session.prepareToDelete(worktree: clone.linked, limit: 5)
        #expect(choice.remoteBranch?.ref == "refs/remotes/origin/topic")
        #expect(choice.widest == .everything)

        try await runGit("update-ref", "-d", "refs/remotes/origin/topic", in: clone.work)
        choice = try await clone.session.prepareToDelete(worktree: clone.linked, limit: 5)
        #expect(choice.remoteBranch == nil)
    }

    @Test func startsWithTheBranchWhenThatLosesNothing() async throws {
        let clone = try await clone()
        let choice = try await clone.session.prepareToDelete(worktree: clone.linked, limit: 5)
        #expect(choice.startingScope == .worktreeAndBranch)
        #expect(choice.asksFirst)
        #expect(!choice.deletion(for: choice.startingScope).asksFirst)
    }

    @Test func startsWithoutTheBranchWhenThatLosesCommits() async throws {
        let clone = try await clone()
        try await commit("Only here", in: clone.linked)
        let choice = try await clone.session.prepareToDelete(worktree: clone.linked, limit: 5)
        #expect(choice.startingScope == .worktree)
        #expect(choice.asksFirst)
        #expect(!choice.deletion(for: .worktree).asksFirst)
        #expect(choice.deletion(for: .worktreeAndBranch).asksFirst)
    }

    @Test func neverStartsByReachingARemote() async throws {
        let clone = try await clone()
        try await commit("Pushed", in: clone.linked)
        try await push(in: clone)
        let choice = try await clone.session.prepareToDelete(worktree: clone.linked, limit: 5)
        #expect(choice.startingScope == .worktreeAndBranch)
        #expect(choice.mostCommands == 3)
    }

    @Test func aWorktreeWithNoBranchHasNothingToChooseAndAsksOnlyAboutWhatItLoses() async throws {
        let clone = try await clone()
        try await runGit("switch", "--quiet", "--detach", in: clone.linked)
        var choice = try await clone.session.prepareToDelete(worktree: clone.linked, limit: 5)
        #expect(choice.branch == nil)
        #expect(choice.widest == .worktree)
        #expect(!choice.asksFirst)

        try await commit("Detached", in: clone.linked)
        choice = try await clone.session.prepareToDelete(worktree: clone.linked, limit: 5)
        #expect(choice.asksFirst)
        #expect(choice.deletion(for: .everything) == choice.deletion(for: .worktree))
    }

    @Test func aWorktreeGitWillRefuseAsksNothing() async throws {
        let clone = try await clone()
        try await runGit("worktree", "lock", clone.linked, in: clone.work)
        let choice = try await clone.session.prepareToDelete(worktree: clone.linked, limit: 5)
        #expect(!choice.asksFirst)
    }

    @Test func theWidestScopeLosesEverythingTheOthersDo() async throws {
        let clone = try await clone()
        let pushed = try await commit("Pushed", in: clone.linked)
        try await push(in: clone)
        let local = try await commit("Only here", in: clone.linked)
        let choice = try await clone.session.prepareToDelete(worktree: clone.linked, limit: 5)
        #expect(choice.deletion(for: .worktree).lostCount == 0)
        #expect(choice.deletion(for: .worktreeAndBranch).lost.map(\.hex) == [local])
        #expect(choice.deletion(for: WorktreeDeletion.Scope(deletesRemoteBranch: true)).lostCount == 0)
        #expect(choice.deletion(for: choice.widest).lost.map(\.hex) == [local, pushed])
    }

    @Test func deletesTheRemoteBranchAndKeepsItsOwn() async throws {
        let clone = try await clone()
        try await push(in: clone)
        let choice = try await clone.session.prepareToDelete(worktree: clone.linked, limit: 5)
        let deletion = choice.deletion(for: WorktreeDeletion.Scope(deletesRemoteBranch: true))
        #expect(deletion.asksFirst)
        #expect(deletion.commands == [
            ["worktree", "remove", clone.linked],
            ["push", "--delete", "origin", "refs/heads/topic"],
        ])

        try await clone.session.delete(deletion)
        #expect(!folderExists(clone))
        #expect(try await exists("refs/heads/topic", in: clone.work))
        #expect(try await !exists("refs/heads/topic", in: clone.remote))
    }

    @Test func countsWhatOnlyTheRemoteBranchHasWhenItGoesAlone() async throws {
        let clone = try await clone()
        let onlyThere = try await commit("Only on the remote", in: clone.linked)
        try await push(in: clone)
        try await runGit("reset", "--quiet", "--hard", "HEAD~1", in: clone.linked)
        let choice = try await clone.session.prepareToDelete(worktree: clone.linked, limit: 5)
        let deletion = choice.deletion(for: WorktreeDeletion.Scope(deletesRemoteBranch: true))
        #expect(deletion.lost.map(\.hex) == [onlyThere])
    }

    // MARK: When git refuses

    @Test func aLockedWorktreeStopsEverythingWithoutAsking() async throws {
        let clone = try await clone()
        try await push(in: clone)
        try "new".write(toFile: clone.linked + "/untracked.txt", atomically: true, encoding: .utf8)
        try await runGit("worktree", "lock", "--reason", "agent running", clone.linked, in: clone.work)
        let deletion = try await prepare(.everything, in: clone)
        #expect(deletion.isRefused)
        #expect(!deletion.asksFirst)

        let error = await #expect(throws: GitError.self) {
            try await clone.session.delete(deletion)
        }
        #expect(error?.message.contains("agent running") == true)
        #expect(folderExists(clone))
        #expect(try await exists("refs/heads/topic", in: clone.work))
        #expect(try await exists("refs/heads/topic", in: clone.remote))
    }

    @Test func gitRefusesTheMainWorktree() async throws {
        let clone = try await clone()
        let deletion = try await clone.session.prepareToDelete(worktree: clone.work, limit: 5).deletion(for: .worktree)
        #expect(deletion.isRefused)
        await #expect(throws: GitError.self) {
            try await clone.session.delete(deletion)
        }
        #expect(FileManager.default.fileExists(atPath: clone.work))
    }

    @Test func deletesAWorktreeWhoseFolderIsMissing() async throws {
        let clone = try await clone()
        try FileManager.default.removeItem(atPath: clone.linked)
        let deletion = try await prepare(.worktreeAndBranch, in: clone)
        #expect(deletion.uncommittedFiles == 0)
        #expect(!deletion.asksFirst)

        try await clone.session.delete(deletion)
        #expect(try await !isListed(clone))
        #expect(try await !exists("refs/heads/topic", in: clone.work))
    }

    @Test func aWorktreeThatsNoLongerListedGetsGitsAnswer() async throws {
        let clone = try await clone()
        let deletion = try await prepare(.worktree, in: clone)
        try await runGit("worktree", "remove", clone.linked, in: clone.work)
        await #expect(throws: GitError.self) {
            try await clone.session.delete(deletion)
        }
    }

    @Test func saysWhereItStoppedWhenTheBranchCantBeDeleted() async throws {
        let clone = try await clone()
        try await push(in: clone)
        // A second worktree on the same branch makes git refuse to delete it.
        try await runGit("worktree", "add", "--quiet", "--force", clone.folder + "/second", "topic", in: clone.work)
        let deletion = try await prepare(.everything, in: clone)

        let error = await #expect(throws: WorktreeDeletion.Stopped.self) {
            try await clone.session.delete(deletion)
        }
        #expect(error?.step == .branch)
        #expect(error?.message.isEmpty == false)
        #expect(!folderExists(clone))
        #expect(try await exists("refs/heads/topic", in: clone.work))
        // The remote wasn't touched.
        #expect(try await exists("refs/heads/topic", in: clone.remote))
    }

    @Test func saysWhereItStoppedWhenTheRemoteCantBeReached() async throws {
        let clone = try await clone()
        try await push(in: clone)
        let deletion = try await prepare(.everything, in: clone)
        try FileManager.default.moveItem(atPath: clone.remote, toPath: clone.remote + ".moved")

        let error = await #expect(throws: WorktreeDeletion.Stopped.self) {
            try await clone.session.delete(deletion)
        }
        #expect(error?.step == .remoteBranch)
        #expect(!folderExists(clone))
        #expect(try await !exists("refs/heads/topic", in: clone.work))
        #expect(try await exists("refs/remotes/origin/topic", in: clone.work))
        #expect(try await exists("refs/heads/topic", in: clone.remote + ".moved"))
    }
}
