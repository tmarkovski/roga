import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Checking out branches, in copies of the `basic` repository. A copy is a clone,
/// so it has a local `main`, and `feature` only as `origin/feature`.
@Suite(.timeLimit(.minutes(1)))
struct BranchCheckoutTests {
    func copy() async throws -> (RepositorySession, repository: String) {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        return (try await openSession(repository), repository)
    }

    func currentBranch(in repository: String) async throws -> String {
        try await runGit("symbolic-ref", "HEAD", in: repository)
    }

    func head(in repository: String) async throws -> ObjectID {
        try #require(ObjectID(hex: try await runGit("rev-parse", "HEAD", in: repository)))
    }

    func upstream(in repository: String) async throws -> String {
        try await runGit("rev-parse", "--abbrev-ref", "@{upstream}", in: repository)
    }

    @Test func switchesToALocalBranch() async throws {
        let (session, repository) = try await copy()
        try await runGit("branch", "other", in: repository)
        let result = try await session.checkOut(ref: "refs/heads/other", in: repository)
        #expect(result == .checkedOut("refs/heads/other", commit: try await head(in: repository)))
        #expect(try await currentBranch(in: repository) == "refs/heads/other")
    }

    @Test func staysOnTheCurrentBranch() async throws {
        let (session, repository) = try await copy()
        let result = try await session.checkOut(ref: "refs/heads/main", in: repository)
        #expect(result == .checkedOut("refs/heads/main", commit: try await head(in: repository)))
        #expect(try await currentBranch(in: repository) == "refs/heads/main")
    }

    @Test func createsALocalBranchThatTracksARemoteBranch() async throws {
        let (session, repository) = try await copy()
        let result = try await session.checkOut(ref: "refs/remotes/origin/feature", in: repository)
        #expect(result == .checkedOut("refs/heads/feature", commit: try await head(in: repository)))
        #expect(try await currentBranch(in: repository) == "refs/heads/feature")
        #expect(try await upstream(in: repository) == "origin/feature")
        #expect(try await runGit("rev-parse", "HEAD", in: repository) == Fixture.Basic.feature)
    }

    @Test func switchesToTheLocalBranchOfARemoteBranchAsItIs() async throws {
        let (session, repository) = try await copy()
        try await runGit("branch", "--no-track", "feature", "main~1", in: repository)
        let local = try await runGit("rev-parse", "feature", in: repository)
        #expect(local != Fixture.Basic.feature)

        let result = try await session.checkOut(ref: "refs/remotes/origin/feature", in: repository)
        #expect(result == .checkedOut("refs/heads/feature", commit: try await head(in: repository)))
        #expect(try await currentBranch(in: repository) == "refs/heads/feature")
        #expect(try await runGit("rev-parse", "HEAD", in: repository) == local)
    }

    @Test(arguments: ["team/fork", "team"]) func findsTheBranchNameAfterARemoteWithASlash(remote: String) async throws {
        let (session, repository) = try await copy()
        try await runGit("remote", "add", remote, try await Fixture.repository("basic"), in: repository)
        try await runGit("fetch", "--quiet", remote, in: repository)
        let result = try await session.checkOut(ref: "refs/remotes/\(remote)/feature", in: repository)
        #expect(result == .checkedOut("refs/heads/feature", commit: try await head(in: repository)))
        #expect(try await upstream(in: repository) == "\(remote)/feature")
    }

    @Test func keepsTheSlashesInARemoteBranchsName() async throws {
        let (session, repository) = try await copy()
        try await runGit("update-ref", "refs/remotes/origin/fix/login", "origin/feature", in: repository)
        let result = try await session.checkOut(ref: "refs/remotes/origin/fix/login", in: repository)
        #expect(result == .checkedOut("refs/heads/fix/login", commit: try await head(in: repository)))
    }

    @Test func doesntTakeABranchNameForAnOption() async throws {
        let (session, repository) = try await copy()
        try await runGit("update-ref", "refs/heads/--detach", "HEAD", in: repository)
        let result = try await session.checkOut(ref: "refs/heads/--detach", in: repository)
        #expect(result == .checkedOut("refs/heads/--detach", commit: try await head(in: repository)))
        #expect(try await currentBranch(in: repository) == "refs/heads/--detach")
    }

    @Test func picksTheBranchOverATagOfTheSameName() async throws {
        let (session, repository) = try await copy()
        try await runGit("branch", "same", "main~1", in: repository)
        try await runGit("tag", "same", "main", in: repository)
        _ = try await session.checkOut(ref: "refs/heads/same", in: repository)
        #expect(try await currentBranch(in: repository) == "refs/heads/same")
        #expect(try await runGit("rev-parse", "HEAD", in: repository) == Fixture.Basic.mainHistory[1])
    }

    @Test func pointsToTheWorktreeThatHasTheBranch() async throws {
        let (session, repository) = try await copy()
        let folder = (repository as NSString).deletingLastPathComponent + "/notes"
        try await runGit("worktree", "add", "--quiet", folder, "-b", "feature", "origin/feature", in: repository)

        let commit = ObjectID(hex: Fixture.Basic.feature)
        #expect(try await session.checkOut(ref: "refs/heads/feature", in: repository) == .inOtherWorktree(folder, commit: commit))
        #expect(try await session.checkOut(ref: "refs/remotes/origin/feature", in: repository) == .inOtherWorktree(folder, commit: commit))
        #expect(try await currentBranch(in: repository) == "refs/heads/main")
    }

    @Test func letsGitSayWhatToDoAboutAWorktreeThatsGone() async throws {
        let (session, repository) = try await copy()
        let folder = (repository as NSString).deletingLastPathComponent + "/notes"
        try await runGit("worktree", "add", "--quiet", folder, "-b", "feature", "origin/feature", in: repository)
        try FileManager.default.removeItem(atPath: folder)

        await #expect(throws: GitError.self) {
            _ = try await session.checkOut(ref: "refs/heads/feature", in: repository)
        }
    }

    /// Commits a change to `README.md` on a new branch, and goes back to main.
    func makeBranchThatChangesTheReadme(in repository: String) async throws {
        try await runGit("switch", "--quiet", "--create", "changed", in: repository)
        try Data("Changed\n".utf8).write(to: URL(filePath: repository + "/README.md"))
        try await runGit("commit", "--quiet", "--all", "--message=Change", in: repository)
        try await runGit("switch", "--quiet", "main", in: repository)
    }

    @Test func leavesChangesThatGitWouldOverwrite() async throws {
        let (session, repository) = try await copy()
        try await makeBranchThatChangesTheReadme(in: repository)
        try Data("Mine\n".utf8).write(to: URL(filePath: repository + "/README.md"))

        do {
            _ = try await session.checkOut(ref: "refs/heads/changed", in: repository)
            Issue.record("git should have refused.")
        } catch let error as GitError {
            #expect(error.message.contains("would be overwritten"))
            #expect(!error.message.contains("git "))
        }
        #expect(try await currentBranch(in: repository) == "refs/heads/main")
        #expect(try String(contentsOfFile: repository + "/README.md", encoding: .utf8) == "Mine\n")
    }

    @Test func keepsChangesThatGitCanCarryOver() async throws {
        let (session, repository) = try await copy()
        try await makeBranchThatChangesTheReadme(in: repository)
        try Data("New\n".utf8).write(to: URL(filePath: repository + "/new.txt"))

        _ = try await session.checkOut(ref: "refs/heads/changed", in: repository)
        #expect(try await currentBranch(in: repository) == "refs/heads/changed")
        #expect(try String(contentsOfFile: repository + "/new.txt", encoding: .utf8) == "New\n")
    }

    @Test func refusesInABareRepository() async throws {
        let folder = try makeTemporaryFolder() + "/bare.git"
        try await runGit("clone", "--quiet", "--bare", "--no-local", try await Fixture.repository("basic"), folder, in: try await Fixture.repository("basic"))
        let session = try await openSession(folder)
        await #expect(throws: GitError.self) {
            _ = try await session.checkOut(ref: "refs/heads/feature", in: folder)
        }
    }
}
