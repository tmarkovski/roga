import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Going to a commit, in clones of a bare copy of the `basic` repository, so that
/// `main` has an upstream to be pushed to or not.
@Suite(.timeLimit(.minutes(1)))
struct CommitSwitchTests {
    func clone() async throws -> (RepositorySession, repository: String) {
        let root = try makeTemporaryFolder()
        let fixture = try await Fixture.repository("basic")
        try await runGit("clone", "--quiet", "--bare", "--no-local", fixture, root + "/remote.git", in: root)
        try await runGit("clone", "--quiet", root + "/remote.git", root + "/work", in: root)
        try await runGit("config", "user.name", "T", in: root + "/work")
        try await runGit("config", "user.email", "t@example.com", in: root + "/work")
        return (try await openSession(root + "/work"), root + "/work")
    }

    func id(_ revision: String, in repository: String) async throws -> ObjectID {
        try #require(ObjectID(hex: try await runGit("rev-parse", revision, in: repository)))
    }

    @discardableResult
    func commit(_ message: String, in repository: String) async throws -> ObjectID {
        try await runGit("commit", "--quiet", "--allow-empty", "-m", message, in: repository)
        return try await id("HEAD", in: repository)
    }

    func prepare(_ session: RepositorySession, to commit: ObjectID, in repository: String, limit: Int = 5) async throws -> CommitSwitch {
        try await session.prepareToSwitch(to: commit, limit: limit, in: repository)
    }

    // MARK: Going back on the branch

    @Test func movesTheBranchBackWithoutAskingWhenEverythingIsPushed() async throws {
        let (session, repository) = try await clone()
        let target = try await id("HEAD~1", in: repository)
        let commitSwitch = try await prepare(session, to: target, in: repository)
        #expect(commitSwitch.way == .movingBranch("refs/heads/main"))
        #expect(commitSwitch.lostCount == 0)
        #expect(!commitSwitch.asksFirst)
        #expect(commitSwitch.arguments == ["reset", "--keep", target.hex])

        try await session.run(commitSwitch, in: repository)
        #expect(try await runGit("symbolic-ref", "HEAD", in: repository) == "refs/heads/main")
        #expect(try await id("HEAD", in: repository) == target)
    }

    @Test func countsCommitsThatArentPushed() async throws {
        let (session, repository) = try await clone()
        let target = try await id("HEAD", in: repository)
        let first = try await commit("One", in: repository)
        let second = try await commit("Two", in: repository)
        let commitSwitch = try await prepare(session, to: target, in: repository)
        #expect(commitSwitch.way == .movingBranch("refs/heads/main"))
        #expect(commitSwitch.lostCount == 2)
        #expect(commitSwitch.lost == [second, first])
        #expect(commitSwitch.asksFirst)
    }

    @Test func listsNoMoreThanItsLimitButCountsThemAll() async throws {
        let (session, repository) = try await clone()
        let target = try await id("HEAD", in: repository)
        for number in 1...3 { try await commit("\(number)", in: repository) }
        let commitSwitch = try await prepare(session, to: target, in: repository, limit: 2)
        #expect(commitSwitch.lostCount == 3)
        #expect(commitSwitch.lost.count == 2)
    }

    @Test func onlyCountsCommitsPastTheOneItGoesTo() async throws {
        let (session, repository) = try await clone()
        try await commit("One", in: repository)
        let target = try await commit("Two", in: repository)
        let third = try await commit("Three", in: repository)
        let commitSwitch = try await prepare(session, to: target, in: repository)
        #expect(commitSwitch.lostCount == 1)
        #expect(commitSwitch.lost == [third])
    }

    @Test func commitsOnAnotherBranchOrATagArentLost() async throws {
        let (session, repository) = try await clone()
        let target = try await id("HEAD", in: repository)
        try await commit("Kept by a branch", in: repository)
        try await runGit("branch", "keeper", in: repository)
        try await commit("Kept by a tag", in: repository)
        try await runGit("tag", "kept", in: repository)
        let commitSwitch = try await prepare(session, to: target, in: repository)
        #expect(commitSwitch.lostCount == 0)
    }

    @Test func commitsAnotherWorktreeIsOnArentLost() async throws {
        let (session, repository) = try await clone()
        let target = try await id("HEAD", in: repository)
        try await commit("Kept by a worktree", in: repository)
        let other = try makeTemporaryFolder() + "/other"
        try await runGit("worktree", "add", "--quiet", "--detach", other, "HEAD", in: repository)
        try await commit("Not kept", in: repository)
        let commitSwitch = try await prepare(session, to: target, in: repository)
        #expect(commitSwitch.lostCount == 1)
    }

    // MARK: Moving along the upstream

    @Test func movesForwardAlongTheUpstreamWithoutLosingAnything() async throws {
        let (session, repository) = try await clone()
        let tip = try await id("HEAD", in: repository)
        try await runGit("reset", "--quiet", "--keep", "HEAD~1", in: repository)
        let commitSwitch = try await prepare(session, to: tip, in: repository)
        #expect(commitSwitch.way == .movingBranch("refs/heads/main"))
        #expect(commitSwitch.lostCount == 0)
        try await session.run(commitSwitch, in: repository)
        #expect(try await id("HEAD", in: repository) == tip)
        #expect(try await runGit("symbolic-ref", "HEAD", in: repository) == "refs/heads/main")
    }

    @Test func goingToTheUpstreamOfADivergedBranchCountsTheBranchsOwnCommits() async throws {
        let (session, repository) = try await clone()
        let upstream = try await id("origin/main", in: repository)
        try await runGit("reset", "--quiet", "--keep", "HEAD~1", in: repository)
        let mine = try await commit("Mine", in: repository)
        let commitSwitch = try await prepare(session, to: upstream, in: repository)
        #expect(commitSwitch.way == .movingBranch("refs/heads/main"))
        #expect(commitSwitch.lost == [mine])
        // What's staged would also undo the upstream's commit.
        #expect(commitSwitch.keepingChanges == nil)
    }

    // MARK: Another line

    @Test func detachesForACommitOnAnotherLine() async throws {
        let (session, repository) = try await clone()
        try await runGit("switch", "--quiet", "--create", "side", "origin/feature", in: repository)
        let onSide = try await commit("On side", in: repository)
        try await commit("Further on side", in: repository)
        try await runGit("switch", "--quiet", "main", in: repository)
        let tip = try await id("main", in: repository)

        let commitSwitch = try await prepare(session, to: onSide, in: repository)
        #expect(commitSwitch.way == .detaching)
        #expect(commitSwitch.lostCount == 0)
        #expect(commitSwitch.arguments == ["switch", "--detach", onSide.hex])

        try await session.run(commitSwitch, in: repository)
        #expect(try await id("HEAD", in: repository) == onSide)
        // The branch stays where it was, so it hasn't lost anything.
        #expect(try await id("main", in: repository) == tip)
        await #expect(throws: (any Error).self) { try await runGit("symbolic-ref", "--quiet", "HEAD", in: repository) }
    }

    @Test func leavingADetachedHeadCountsWhatOnlyItLeadsTo() async throws {
        let (session, repository) = try await clone()
        let target = try await id("HEAD~1", in: repository)
        try await runGit("switch", "--quiet", "--detach", "HEAD", in: repository)
        let stray = try await commit("On no branch", in: repository)
        let commitSwitch = try await prepare(session, to: target, in: repository)
        #expect(commitSwitch.way == .detaching)
        #expect(commitSwitch.lost == [stray])
    }

    // MARK: Uncommitted changes

    @Test func carriesUncommittedChangesAlong() async throws {
        let (session, repository) = try await clone()
        let target = try await id("HEAD~1", in: repository)
        let changed = try await runGit("diff", "--name-only", target.hex, "HEAD", in: repository).split(separator: "\n")
        let tracked = try await runGit("ls-files", in: repository).split(separator: "\n")
        let file = String(try #require(tracked.first { !changed.contains($0) }))
        try Data("Mine\n".utf8).write(to: URL(filePath: repository + "/" + file))
        try Data("Mine\n".utf8).write(to: URL(filePath: repository + "/new.txt"))

        try await session.run(try await prepare(session, to: target, in: repository), in: repository)
        #expect(try await id("HEAD", in: repository) == target)
        #expect(try String(contentsOfFile: repository + "/" + file, encoding: .utf8) == "Mine\n")
        #expect(try String(contentsOfFile: repository + "/new.txt", encoding: .utf8) == "Mine\n")
    }

    @Test func gitRefusesWhenUncommittedChangesAreInTheWay() async throws {
        let (session, repository) = try await clone()
        let head = try await id("HEAD", in: repository)
        let target = try await id("HEAD~1", in: repository)
        let changed = try await runGit("diff", "--name-only", target.hex, "HEAD", in: repository)
        let file = try #require(changed.split(separator: "\n").first.map(String.init))
        try Data("Mine\n".utf8).write(to: URL(filePath: repository + "/" + file))

        let commitSwitch = try await prepare(session, to: target, in: repository)
        await #expect(throws: GitError.self) { try await session.run(commitSwitch, in: repository) }
        #expect(try await id("HEAD", in: repository) == head)
        #expect(try String(contentsOfFile: repository + "/" + file, encoding: .utf8) == "Mine\n")
    }

    // MARK: Keeping the changes

    @Test func keepingChangesLeavesWhatTheCommitsChangedStaged() async throws {
        let (session, repository) = try await clone()
        let target = try await id("HEAD", in: repository)
        try Data("Mine\n".utf8).write(to: URL(filePath: repository + "/mine.txt"))
        try await runGit("add", "mine.txt", in: repository)
        try await commit("Mine", in: repository)

        let commitSwitch = try await prepare(session, to: target, in: repository)
        #expect(commitSwitch.asksFirst)
        let keeping = try #require(commitSwitch.keepingChanges)
        #expect(keeping.arguments == ["reset", "--soft", target.hex])

        try await session.run(keeping, in: repository)
        #expect(try await id("HEAD", in: repository) == target)
        #expect(try await runGit("diff", "--cached", "--name-only", in: repository) == "mine.txt")
        #expect(try String(contentsOfFile: repository + "/mine.txt", encoding: .utf8) == "Mine\n")
    }

    @Test func keepingChangesLeavesUncommittedChangesAsTheyWere() async throws {
        let (session, repository) = try await clone()
        let target = try await id("HEAD", in: repository)
        try Data("One\n".utf8).write(to: URL(filePath: repository + "/mine.txt"))
        try await runGit("add", "mine.txt", in: repository)
        try await commit("Mine", in: repository)
        // A change that `--keep` would refuse to carry past the commit that made the file.
        try Data("Two\n".utf8).write(to: URL(filePath: repository + "/mine.txt"))
        try Data("Staged\n".utf8).write(to: URL(filePath: repository + "/staged.txt"))
        try await runGit("add", "staged.txt", in: repository)

        let commitSwitch = try await prepare(session, to: target, in: repository)
        await #expect(throws: GitError.self) { try await session.run(commitSwitch, in: repository) }

        try await session.run(try #require(commitSwitch.keepingChanges), in: repository)
        #expect(try await id("HEAD", in: repository) == target)
        #expect(try String(contentsOfFile: repository + "/mine.txt", encoding: .utf8) == "Two\n")
        #expect(try await runGit("diff", "--cached", "--name-only", in: repository) == "mine.txt\nstaged.txt")
        #expect(try await runGit("show", ":mine.txt", in: repository) == "One")
    }

    @Test func keepingChangesRefusesWhenHeadHasMovedSinceItCounted() async throws {
        let (session, repository) = try await clone()
        let target = try await id("HEAD~1", in: repository)
        let keeping = try #require(try await prepare(session, to: target, in: repository).keepingChanges)
        let new = try await commit("Made meanwhile", in: repository)
        await #expect(throws: CommitSwitch.Outdated.self) { try await session.run(keeping, in: repository) }
        #expect(try await id("HEAD", in: repository) == new)
    }

    @Test func refusesWhenHeadHasMovedSinceItCounted() async throws {
        let (session, repository) = try await clone()
        let target = try await id("HEAD~1", in: repository)
        let commitSwitch = try await prepare(session, to: target, in: repository)
        // An agent commits while the dialog waits.
        let new = try await commit("Made meanwhile", in: repository)
        await #expect(throws: CommitSwitch.Outdated.self) { try await session.run(commitSwitch, in: repository) }
        #expect(try await id("HEAD", in: repository) == new)
    }
}
