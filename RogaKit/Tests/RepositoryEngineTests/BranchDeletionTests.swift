import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Deleting branches, in a clone of a bare copy of the `basic` repository. The
/// clone has a local `main`, and `feature` only as `origin/feature`.
@Suite(.timeLimit(.minutes(1)))
struct BranchDeletionTests {
    struct Clone {
        var folder: String
        var remote: String
        var work: String
        var session: RepositorySession
    }

    func clone() async throws -> Clone {
        let fixture = try await Fixture.repository("basic")
        let folder = try makeTemporaryFolder()
        let remote = folder + "/remote.git"
        try await runGit("clone", "--quiet", "--bare", "--no-local", fixture, remote, in: fixture)
        try await runGit("clone", "--quiet", remote, folder + "/work", in: folder)
        let session = try await RepositorySession.open(containing: folder + "/work", git: try await TestGit.make())
        return Clone(folder: folder, remote: remote, work: folder + "/work", session: session)
    }

    @discardableResult
    func commit(_ message: String, in folder: String) async throws -> String {
        try await runGit("-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "--quiet", "--allow-empty", "-m", message, in: folder)
        return try await runGit("rev-parse", "HEAD", in: folder)
    }

    /// Makes a branch off `main` with commits of its own, and goes back to `main`.
    /// It returns the commits, newest first.
    @discardableResult
    func makeBranch(_ name: String, commits: Int, in folder: String) async throws -> [String] {
        try await runGit("switch", "--quiet", "--create", name, "main", in: folder)
        var made: [String] = []
        for index in 0..<commits { made.insert(try await commit("Commit \(index)", in: folder), at: 0) }
        try await runGit("switch", "--quiet", "main", in: folder)
        return made
    }

    func exists(_ ref: String, in folder: String) async throws -> Bool {
        try await !runGit("for-each-ref", "--format=%(refname)", ref, in: folder).isEmpty
    }

    func prepare(_ ref: String, in clone: Clone, limit: Int = 5) async throws -> BranchDeletion {
        try await clone.session.prepareToDelete(ref: ref, limit: limit, in: clone.work)
    }

    // MARK: Local branches

    @Test func deletesABranchThatLosesNothingWithoutAsking() async throws {
        let clone = try await clone()
        try await runGit("branch", "other", in: clone.work)
        let deletion = try await prepare("refs/heads/other", in: clone)
        #expect(deletion.place == .local)
        #expect(deletion.lostCount == 0)
        #expect(deletion.lost.isEmpty)
        #expect(!deletion.asksFirst)

        try await clone.session.delete(deletion, in: clone.work)
        #expect(try await !exists("refs/heads/other", in: clone.work))
    }

    @Test func asksAboutTheCommitsOnlyThisBranchHas() async throws {
        let clone = try await clone()
        let made = try await makeBranch("other", commits: 3, in: clone.work)
        let deletion = try await prepare("refs/heads/other", in: clone, limit: 2)
        #expect(deletion.asksFirst)
        #expect(deletion.lostCount == 3)
        #expect(deletion.lost.map(\.hex) == Array(made.prefix(2)))
        // Asking changes nothing.
        #expect(try await exists("refs/heads/other", in: clone.work))

        try await clone.session.delete(deletion, in: clone.work)
        #expect(try await !exists("refs/heads/other", in: clone.work))
    }

    /// `git branch -d` would refuse this one, because `HEAD` doesn't have them.
    @Test func doesntCountCommitsThatAnotherBranchHas() async throws {
        let clone = try await clone()
        try await makeBranch("other", commits: 1, in: clone.work)
        try await runGit("branch", "keeper", "other", in: clone.work)
        let deletion = try await prepare("refs/heads/other", in: clone)
        #expect(deletion.lostCount == 0)

        try await clone.session.delete(deletion, in: clone.work)
        #expect(try await !exists("refs/heads/other", in: clone.work))
        #expect(try await exists("refs/heads/keeper", in: clone.work))
    }

    @Test func doesntCountCommitsThatATagHas() async throws {
        let clone = try await clone()
        try await makeBranch("other", commits: 1, in: clone.work)
        try await runGit("tag", "kept", "other", in: clone.work)
        #expect(try await prepare("refs/heads/other", in: clone).lostCount == 0)
    }

    @Test func deletesABranchNamedLikeAnOption() async throws {
        let clone = try await clone()
        try await runGit("update-ref", "refs/heads/--detach", "HEAD", in: clone.work)
        try await clone.session.delete(try await prepare("refs/heads/--detach", in: clone), in: clone.work)
        #expect(try await !exists("refs/heads/--detach", in: clone.work))
    }

    @Test func leavesATagOfTheSameName() async throws {
        let clone = try await clone()
        try await runGit("branch", "same", in: clone.work)
        try await runGit("tag", "same", in: clone.work)
        try await clone.session.delete(try await prepare("refs/heads/same", in: clone), in: clone.work)
        #expect(try await !exists("refs/heads/same", in: clone.work))
        #expect(try await exists("refs/tags/same", in: clone.work))
    }

    @Test func doesntAskAboutWhatGitWillRefuse() async throws {
        let clone = try await clone()
        let folder = clone.folder + "/notes"
        try await runGit("worktree", "add", "--quiet", folder, "-b", "notes", in: clone.work)
        try await commit("Only here", in: folder)
        let deletion = try await prepare("refs/heads/notes", in: clone)
        #expect(deletion.isCheckedOut)
        #expect(!deletion.asksFirst)

        do {
            try await clone.session.delete(deletion, in: clone.work)
            Issue.record("git should have refused.")
        } catch let error as GitError {
            #expect(error.message.contains(folder))
        }
        #expect(try await exists("refs/heads/notes", in: clone.work))
    }

    @Test func refusesTheCurrentBranch() async throws {
        let clone = try await clone()
        let deletion = try await prepare("refs/heads/main", in: clone)
        #expect(deletion.isCheckedOut)
        await #expect(throws: GitError.self) {
            try await clone.session.delete(deletion, in: clone.work)
        }
        #expect(try await exists("refs/heads/main", in: clone.work))
    }

    /// The worktree's `HEAD` still counts until it's pruned, so this doesn't ask
    /// about its commits. They're safe, because git refuses and says why.
    @Test func letsGitSayWhatToDoAboutAWorktreeThatsGone() async throws {
        let clone = try await clone()
        let folder = clone.folder + "/notes"
        try await runGit("worktree", "add", "--quiet", folder, "-b", "notes", in: clone.work)
        try await commit("Only here", in: folder)
        try FileManager.default.removeItem(atPath: folder)
        let deletion = try await prepare("refs/heads/notes", in: clone)
        #expect(deletion.isCheckedOut)
        #expect(!deletion.asksFirst)

        await #expect(throws: GitError.self) {
            try await clone.session.delete(deletion, in: clone.work)
        }
        #expect(try await exists("refs/heads/notes", in: clone.work))
    }

    // MARK: Remote branches

    @Test func deletesARemoteBranchFromTheRemoteAndHere() async throws {
        let clone = try await clone()
        let deletion = try await prepare("refs/remotes/origin/feature", in: clone)
        #expect(deletion.place == .remote("origin", branch: "feature"))
        #expect(deletion.asksFirst)

        try await clone.session.delete(deletion, in: clone.work)
        #expect(try await !exists("refs/heads/feature", in: clone.remote))
        #expect(try await !exists("refs/remotes/origin/feature", in: clone.work))
    }

    @Test func alwaysAsksBeforeDeletingFromARemote() async throws {
        let clone = try await clone()
        try await runGit("branch", "--track", "feature", "origin/feature", in: clone.work)
        let deletion = try await prepare("refs/remotes/origin/feature", in: clone)
        #expect(deletion.lostCount == 0)
        #expect(deletion.asksFirst)
    }

    @Test func leavesATagOfTheSameNameOnTheRemote() async throws {
        let clone = try await clone()
        try await runGit("tag", "feature", in: clone.remote)
        try await clone.session.delete(try await prepare("refs/remotes/origin/feature", in: clone), in: clone.work)
        #expect(try await !exists("refs/heads/feature", in: clone.remote))
        #expect(try await exists("refs/tags/feature", in: clone.remote))
    }

    @Test(arguments: ["team/fork", "team"]) func findsTheBranchAfterARemoteWithASlash(remote: String) async throws {
        let clone = try await clone()
        try await runGit("remote", "add", remote, clone.remote, in: clone.work)
        try await runGit("fetch", "--quiet", remote, in: clone.work)
        let deletion = try await prepare("refs/remotes/\(remote)/feature", in: clone)
        #expect(deletion.place == .remote(remote, branch: "feature"))
        #expect(deletion.shortName == "\(remote)/feature")
    }

    @Test func keepsTheSlashesInARemoteBranchsName() async throws {
        let clone = try await clone()
        try await runGit("branch", "fix/login", "feature", in: clone.remote)
        try await runGit("fetch", "--quiet", in: clone.work)
        let deletion = try await prepare("refs/remotes/origin/fix/login", in: clone)
        #expect(deletion.place == .remote("origin", branch: "fix/login"))
        try await clone.session.delete(deletion, in: clone.work)
        #expect(try await !exists("refs/heads/fix/login", in: clone.remote))
    }

    /// `origin/HEAD` points to `origin/main`, and would go along with it.
    @Test func aSymbolicRefDoesntKeepItsBranchsCommits() async throws {
        let clone = try await clone()
        try await runGit("clone", "--quiet", clone.remote, clone.folder + "/other", in: clone.folder)
        try await commit("From someone else", in: clone.folder + "/other")
        try await runGit("push", "--quiet", in: clone.folder + "/other")
        try await runGit("fetch", "--quiet", in: clone.work)
        #expect(try await runGit("symbolic-ref", "refs/remotes/origin/HEAD", in: clone.work) == "refs/remotes/origin/main")
        #expect(try await prepare("refs/remotes/origin/main", in: clone).lostCount == 1)
    }

    // MARK: The branches on a commit

    func prepare(branches names: [String], on commit: String, in clone: Clone, limit: Int = 5) async throws -> CommitBranchesDeletion {
        try await clone.session.prepareToDelete(branches: names, on: try #require(ObjectID(hex: commit)), limit: limit, in: clone.work)
    }

    @Test func countsWhatGoesWhenEveryBranchOnACommitDoes() async throws {
        let clone = try await clone()
        let made = try await makeBranch("topic", commits: 2, in: clone.work)
        try await runGit("push", "--quiet", "origin", "topic", in: clone.work)
        let deletion = try await prepare(branches: ["refs/heads/topic", "refs/remotes/origin/topic"], on: made[0], in: clone)
        #expect(deletion.branches.map(\.ref) == ["refs/heads/topic", "refs/remotes/origin/topic"])
        #expect(deletion.branches.map(\.place) == [.local, .remote("origin", branch: "topic")])
        #expect(deletion.lostCount == 2)
        #expect(deletion.lost.map(\.hex) == made)
        // Either one staying keeps them.
        #expect(deletion.branches.map(\.lostCount) == [0, 0])
        #expect(deletion.checkedOut.isEmpty)
    }

    @Test func givesALoneBranchTheCountOfTheCommit() async throws {
        let clone = try await clone()
        let made = try await makeBranch("topic", commits: 2, in: clone.work)
        let deletion = try await prepare(branches: ["refs/heads/topic"], on: made[0], in: clone, limit: 1)
        let only = try #require(deletion.branches.first)
        #expect(only.lostCount == 2)
        #expect(only.lost.map(\.hex) == [made[0]])
        #expect(only.asksFirst)
    }

    @Test func aTagKeepsTheCommitsOfEveryBranchOnACommit() async throws {
        let clone = try await clone()
        let made = try await makeBranch("topic", commits: 1, in: clone.work)
        try await runGit("tag", "kept", "topic", in: clone.work)
        let deletion = try await prepare(branches: ["refs/heads/topic"], on: made[0], in: clone)
        #expect(deletion.lostCount == 0)
        #expect(deletion.lost.isEmpty)
    }

    @Test func aCheckedOutBranchStaysAndKeepsTheCommits() async throws {
        let clone = try await clone()
        let folder = clone.folder + "/notes"
        try await runGit("worktree", "add", "--quiet", folder, "-b", "notes", in: clone.work)
        let tip = try await commit("Only here", in: folder)
        try await runGit("branch", "copy", "notes", in: clone.work)
        let deletion = try await prepare(branches: ["refs/heads/notes", "refs/heads/copy"], on: tip, in: clone)
        #expect(deletion.branches.map(\.ref) == ["refs/heads/copy"])
        #expect(deletion.checkedOut.map(\.ref) == ["refs/heads/notes"])
        #expect(deletion.checkedOut.map(\.isCheckedOut) == [true])
        #expect(deletion.lostCount == 0)
    }

    /// The commits a moved branch reached aren't in what's counted, so it can't stay
    /// in the list as though it lost nothing.
    @Test func leavesOutABranchThatsNoLongerOnTheCommit() async throws {
        let clone = try await clone()
        let made = try await makeBranch("topic", commits: 1, in: clone.work)
        try await runGit("branch", "copy", "topic", in: clone.work)
        try await runGit("switch", "--quiet", "topic", in: clone.work)
        try await commit("Moved on", in: clone.work)
        try await runGit("switch", "--quiet", "main", in: clone.work)
        let deletion = try await prepare(branches: ["refs/heads/topic", "refs/heads/copy", "refs/heads/gone"], on: made[0], in: clone)
        #expect(deletion.branches.map(\.ref) == ["refs/heads/copy"])
        #expect(deletion.checkedOut.isEmpty)
        // `topic` has moved on from there and still holds the commit.
        #expect(deletion.lostCount == 0)
    }

    @Test func aSymbolicRefDoesntKeepTheCommitsOfTheBranchesOnACommit() async throws {
        let clone = try await clone()
        try await runGit("clone", "--quiet", clone.remote, clone.folder + "/other", in: clone.folder)
        let tip = try await commit("From someone else", in: clone.folder + "/other")
        try await runGit("push", "--quiet", in: clone.folder + "/other")
        try await runGit("fetch", "--quiet", in: clone.work)
        let deletion = try await prepare(branches: ["refs/remotes/origin/main"], on: tip, in: clone)
        #expect(deletion.lostCount == 1)
    }

    @Test func aRemoteThatsNotConfiguredIsLeftBehindOnACommit() async throws {
        let clone = try await clone()
        let tip = try await runGit("rev-parse", "origin/feature", in: clone.work)
        try await runGit("update-ref", "refs/remotes/old/feature", tip, in: clone.work)
        let deletion = try await prepare(branches: ["refs/remotes/old/feature", "refs/remotes/origin/feature"], on: tip, in: clone)
        #expect(deletion.branches.map(\.place) == [.leftBehind, .remote("origin", branch: "feature")])
        #expect(deletion.branches.map(\.reachesRemote) == [false, true])
    }

    /// This is a branch that someone merged and deleted on the host, which stays
    /// here because Roga's fetches don't prune.
    @Test func deletesTheCopyOfABranchTheRemoteNoLongerHas() async throws {
        let clone = try await clone()
        try await runGit("branch", "-D", "feature", in: clone.remote)
        let deletion = try await prepare("refs/remotes/origin/feature", in: clone)
        try await clone.session.delete(deletion, in: clone.work)
        #expect(try await !exists("refs/remotes/origin/feature", in: clone.work))
    }

    @Test func keepsTheCopyWhenTheRemoteCantBeReached() async throws {
        let clone = try await clone()
        let deletion = try await prepare("refs/remotes/origin/feature", in: clone)
        try await runGit("remote", "set-url", "origin", clone.folder + "/gone.git", in: clone.work)
        await #expect(throws: GitError.self) {
            try await clone.session.delete(deletion, in: clone.work)
        }
        #expect(try await exists("refs/remotes/origin/feature", in: clone.work))
    }

    @Test func saysWhatARemoteSaidWhenItRefuses() async throws {
        let clone = try await clone()
        let deletion = try await prepare("refs/remotes/origin/main", in: clone)
        do {
            // The remote's `HEAD` points to it.
            try await clone.session.delete(deletion, in: clone.work)
            Issue.record("The remote should have refused.")
        } catch let error as GitError {
            #expect(error.message.contains("refusing to delete the current branch"))
        }
        #expect(try await exists("refs/heads/main", in: clone.remote))
        #expect(try await exists("refs/remotes/origin/main", in: clone.work))
    }

    @Test func deletesWhatARemoteThatsNotConfiguredLeftBehind() async throws {
        let clone = try await clone()
        try await runGit("update-ref", "refs/remotes/old/feature", "HEAD", in: clone.work)
        let deletion = try await prepare("refs/remotes/old/feature", in: clone)
        #expect(deletion.place == .leftBehind)
        #expect(!deletion.asksFirst)
        try await clone.session.delete(deletion, in: clone.work)
        #expect(try await !exists("refs/remotes/old/feature", in: clone.work))
    }

    @Test func runsWhatItShows() async throws {
        let clone = try await clone()
        #expect(try await prepare("refs/remotes/origin/feature", in: clone).arguments == ["push", "--delete", "origin", "refs/heads/feature"])
        try await runGit("branch", "other", in: clone.work)
        #expect(try await prepare("refs/heads/other", in: clone).arguments == ["branch", "-D", "other"])
        try await runGit("update-ref", "refs/heads/--detach", "HEAD", in: clone.work)
        #expect(try await prepare("refs/heads/--detach", in: clone).arguments == ["branch", "-D", "--end-of-options", "--detach"])
    }
}
