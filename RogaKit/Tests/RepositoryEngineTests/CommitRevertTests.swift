import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Reverting a commit from history (decision 44), against real git, in a repository
/// whose `f.txt` reads `a`, `b`, `c` in its first commit, `a`, `B`, `c` in its second,
/// and gains `d` in its third.
@Suite(.timeLimit(.minutes(1)))
struct CommitRevertTests {
    struct Repository {
        var session: RepositorySession
        var path: String
        /// The commit that changed `b` to `B`.
        var changeB: ObjectID
    }

    func makeRepository() async throws -> Repository {
        let path = try makeTemporaryFolder() + "/repository"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--initial-branch=main", in: path)
        try await runGit("config", "user.name", "Ana", in: path)
        try await runGit("config", "user.email", "ana@example.com", in: path)
        try write("a\nb\nc\n", to: "f.txt", in: path)
        try write("x\n", to: "other.txt", in: path)
        try await runGit("add", "--all", in: path)
        try await runGit("commit", "--quiet", "--message=First", in: path)
        try write("a\nB\nc\n", to: "f.txt", in: path)
        try await runGit("commit", "--quiet", "--all", "--message=Change b", in: path)
        let changeB = try await id("HEAD", in: path)
        try write("a\nB\nc\nd\n", to: "f.txt", in: path)
        try await runGit("commit", "--quiet", "--all", "--message=Add d", in: path)
        return Repository(session: try await openSession(path), path: path, changeB: changeB)
    }

    func write(_ text: String, to file: String, in repository: String) throws {
        try Data(text.utf8).write(to: URL(filePath: repository + "/" + file))
    }

    func read(_ file: String, in repository: String) throws -> String {
        try String(contentsOfFile: repository + "/" + file, encoding: .utf8)
    }

    func id(_ revision: String, in repository: String) async throws -> ObjectID {
        try #require(ObjectID(hex: try await runGit("rev-parse", revision, in: repository)))
    }

    func message(of revision: String, in repository: String) async throws -> String {
        try await runGit("log", "-1", "--format=%B", revision, in: repository).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func staged(in repository: String) async throws -> [String] {
        try await runGit("diff", "--cached", "--name-only", in: repository).split(separator: "\n").map(String.init)
    }

    func addHook(_ name: String, in folder: String) throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/" + name
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: URL(filePath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    // MARK: Preparing

    @Test func saysWhatTheCommitIsAndThatItCanBeCommitted() async throws {
        let repository = try await makeRepository()
        let revert = try await repository.session.prepareToRevert(repository.changeB, in: repository.path)
        #expect(revert.subject == "Change b")
        #expect(!revert.isMerge)
        #expect(revert.headContains)
        #expect(revert.stagedCount == 0)
        #expect(revert.canCommit)
        #expect(!revert.hasCommitHooks)
        #expect(revert.arguments(.committing) == ["revert", "--no-edit", repository.changeB.hex])
        #expect(revert.arguments(.leavingUncommitted) == ["revert", "--no-commit", repository.changeB.hex])
    }

    @Test func countsStagedFilesWhichStopItCommitting() async throws {
        let repository = try await makeRepository()
        try write("x\ny\n", to: "other.txt", in: repository.path)
        try await runGit("add", "other.txt", in: repository.path)
        // An unstaged change elsewhere doesn't count.
        try write("u\n", to: "untracked.txt", in: repository.path)
        let revert = try await repository.session.prepareToRevert(repository.changeB, in: repository.path)
        #expect(revert.stagedCount == 1)
        #expect(!revert.canCommit)
    }

    @Test func saysWhenHeadDoesntContainTheCommit() async throws {
        let repository = try await makeRepository()
        try await runGit("switch", "--quiet", "--create", "side", "HEAD~2", in: repository.path)
        try write("side\n", to: "side.txt", in: repository.path)
        try await runGit("add", "side.txt", in: repository.path)
        try await runGit("commit", "--quiet", "--message=Only on side", in: repository.path)
        let side = try await id("HEAD", in: repository.path)
        try await runGit("switch", "--quiet", "main", in: repository.path)

        let revert = try await repository.session.prepareToRevert(side, in: repository.path)
        #expect(!revert.headContains)
        let own = try await repository.session.prepareToRevert(repository.changeB, in: repository.path)
        #expect(own.headContains)
    }

    @Test func findsAHookWhereGitLooksForOne() async throws {
        let repository = try await makeRepository()
        try addHook("pre-commit", in: repository.path + "/.git/hooks")
        let revert = try await repository.session.prepareToRevert(repository.changeB, in: repository.path)
        #expect(revert.hasCommitHooks)
    }

    @Test func followsTheHooksPath() async throws {
        let repository = try await makeRepository()
        try await runGit("config", "core.hooksPath", "my-hooks", in: repository.path)
        try addHook("commit-msg", in: repository.path + "/my-hooks")
        let revert = try await repository.session.prepareToRevert(repository.changeB, in: repository.path)
        #expect(revert.hasCommitHooks)
    }

    @Test func findsAHookInTheConfig() async throws {
        let repository = try await makeRepository()
        try await runGit("config", "hook.lint.command", "true", in: repository.path)
        try await runGit("config", "hook.lint.event", "pre-commit", in: repository.path)
        let revert = try await repository.session.prepareToRevert(repository.changeB, in: repository.path)
        #expect(revert.hasCommitHooks)
    }

    @Test func aHookThatIsntForCommittingDoesntCount() async throws {
        let repository = try await makeRepository()
        try addHook("pre-push", in: repository.path + "/.git/hooks")
        let revert = try await repository.session.prepareToRevert(repository.changeB, in: repository.path)
        #expect(!revert.hasCommitHooks)
    }

    // MARK: Committing

    @Test func commitsWithGitsMessage() async throws {
        let repository = try await makeRepository()
        let revert = try await repository.session.prepareToRevert(repository.changeB, in: repository.path)
        let outcome = try await repository.session.revert(revert, .committing, in: repository.path)
        let head = try await id("HEAD", in: repository.path)
        #expect(outcome == .committed(head))
        #expect(try await message(of: "HEAD", in: repository.path) == "Revert \"Change b\"\n\nThis reverts commit \(repository.changeB.hex).")
        #expect(try read("f.txt", in: repository.path) == "a\nb\nc\nd\n")
        #expect(try await repository.session.stoppedWork(in: repository.path) == nil)
    }

    @Test func gitRefusesToCommitWhileAnythingIsStagedAndChangesNothing() async throws {
        let repository = try await makeRepository()
        try write("x\ny\n", to: "other.txt", in: repository.path)
        try await runGit("add", "other.txt", in: repository.path)
        let head = try await id("HEAD", in: repository.path)
        let revert = try await repository.session.prepareToRevert(repository.changeB, in: repository.path)

        let error = try await #require(throws: GitError.self) {
            try await repository.session.revert(revert, .committing, in: repository.path)
        }
        #expect(error.message.contains("your local changes would be overwritten by revert"))
        #expect(error.command?.arguments == revert.arguments(.committing))
        #expect(try await id("HEAD", in: repository.path) == head)
        #expect(try await staged(in: repository.path) == ["other.txt"])
        #expect(try await repository.session.stoppedWork(in: repository.path) == nil)
    }

    @Test func gitLeavesOutTheCommitHooks() async throws {
        let repository = try await makeRepository()
        try addHook("pre-commit", in: repository.path + "/.git/hooks")
        try addHook("commit-msg", in: repository.path + "/.git/hooks")
        let revert = try await repository.session.prepareToRevert(repository.changeB, in: repository.path)
        let outcome = try await repository.session.revert(revert, .committing, in: repository.path)
        #expect(outcome == .committed(try await id("HEAD", in: repository.path)))
    }

    @Test func revertsAMergeAgainstItsFirstParent() async throws {
        let repository = try await makeRepository()
        try await runGit("switch", "--quiet", "--create", "side", "HEAD~1", in: repository.path)
        try write("side\n", to: "side.txt", in: repository.path)
        try await runGit("add", "side.txt", in: repository.path)
        try await runGit("commit", "--quiet", "--message=Side", in: repository.path)
        try await runGit("switch", "--quiet", "main", in: repository.path)
        try await runGit("merge", "--quiet", "--no-ff", "--no-edit", "side", in: repository.path)
        let merge = try await id("HEAD", in: repository.path)
        let mainline = try await id("HEAD^1", in: repository.path)

        let revert = try await repository.session.prepareToRevert(merge, in: repository.path)
        #expect(revert.isMerge)
        #expect(revert.parents.first == mainline)
        #expect(revert.arguments(.committing) == ["revert", "--no-edit", "-m", "1", merge.hex])
        _ = try await repository.session.revert(revert, .committing, in: repository.path)
        #expect(!FileManager.default.fileExists(atPath: repository.path + "/side.txt"))
        #expect(try read("f.txt", in: repository.path) == "a\nB\nc\nd\n")
        #expect(try await message(of: "HEAD", in: repository.path).contains("reversing\nchanges made to \(mainline.hex)."))
    }

    @Test func revertingWhatsAlreadyRevertedSaysWhy() async throws {
        let repository = try await makeRepository()
        let revert = try await repository.session.prepareToRevert(repository.changeB, in: repository.path)
        _ = try await repository.session.revert(revert, .committing, in: repository.path)

        let again = try await repository.session.prepareToRevert(repository.changeB, in: repository.path)
        // git says this on its standard output, with nothing on standard error.
        let error = try await #require(throws: GitError.self) {
            try await repository.session.revert(again, .committing, in: repository.path)
        }
        #expect(error.message.contains("nothing to commit"))
        #expect(try await repository.session.stoppedWork(in: repository.path) == nil)
    }

    // MARK: Leaving it uncommitted

    @Test func leavesTheChangesStagedWithGitsMessageReady() async throws {
        let repository = try await makeRepository()
        let head = try await id("HEAD", in: repository.path)
        let revert = try await repository.session.prepareToRevert(repository.changeB, in: repository.path)
        let outcome = try await repository.session.revert(revert, .leavingUncommitted, in: repository.path)
        #expect(outcome == .leftUncommitted)
        #expect(try await id("HEAD", in: repository.path) == head)
        #expect(try await staged(in: repository.path) == ["f.txt"])

        let stopped = try await repository.session.stoppedWork(in: repository.path)
        #expect(stopped == .revert(commit: repository.changeB))
        #expect(await repository.session.stoppedWorkFromFiles(in: repository.path) == stopped)
        let ready = try await repository.session.message(for: try #require(stopped), in: repository.path)
        #expect(ready == "Revert \"Change b\"\n\nThis reverts commit \(repository.changeB.hex).")
    }

    @Test func addsToWhatsStaged() async throws {
        let repository = try await makeRepository()
        try write("x\ny\n", to: "other.txt", in: repository.path)
        try await runGit("add", "other.txt", in: repository.path)
        let revert = try await repository.session.prepareToRevert(repository.changeB, in: repository.path)
        #expect(try await repository.session.revert(revert, .leavingUncommitted, in: repository.path) == .leftUncommitted)
        #expect(try await staged(in: repository.path) == ["f.txt", "other.txt"])
    }

    @Test func committingFromTheBoxFinishesTheRevert() async throws {
        let repository = try await makeRepository()
        let revert = try await repository.session.prepareToRevert(repository.changeB, in: repository.path)
        _ = try await repository.session.revert(revert, .leavingUncommitted, in: repository.path)
        _ = try await repository.session.commit(CommitRequest(message: "Put b back"), in: repository.path)
        #expect(try await repository.session.stoppedWork(in: repository.path) == nil)
        #expect(try await message(of: "HEAD", in: repository.path) == "Put b back")
    }

    /// git aborts by taking everything staged back to `HEAD`, which the dialog for
    /// aborting a revert has to say, because it includes what was staged before.
    @Test func abortingTakesBackWhatWasStagedBefore() async throws {
        let repository = try await makeRepository()
        try write("x\ny\n", to: "other.txt", in: repository.path)
        try await runGit("add", "other.txt", in: repository.path)
        let revert = try await repository.session.prepareToRevert(repository.changeB, in: repository.path)
        _ = try await repository.session.revert(revert, .leavingUncommitted, in: repository.path)

        try await repository.session.abort(.revert(commit: repository.changeB), in: repository.path)
        #expect(try await repository.session.stoppedWork(in: repository.path) == nil)
        #expect(try await staged(in: repository.path).isEmpty)
        #expect(try read("other.txt", in: repository.path) == "x\n")
        #expect(try read("f.txt", in: repository.path) == "a\nB\nc\nd\n")
    }

    // MARK: Conflicts

    @Test func stopsOnConflictsWithTheRevertUnderway() async throws {
        let repository = try await makeRepository()
        try write("a\nQ\nc\nd\n", to: "f.txt", in: repository.path)
        try await runGit("commit", "--quiet", "--all", "--message=Change B to Q", in: repository.path)
        let head = try await id("HEAD", in: repository.path)

        let revert = try await repository.session.prepareToRevert(repository.changeB, in: repository.path)
        let outcome = try await repository.session.revert(revert, .committing, in: repository.path)
        #expect(outcome == .stoppedOnConflicts)
        #expect(try await repository.session.stoppedWork(in: repository.path) == .revert(commit: repository.changeB))
        #expect(try await repository.session.status(in: repository.path).conflicted.map(\.path) == ["f.txt"])
        // The lines about the conflicts are comments, which the box leaves out.
        let ready = try await repository.session.message(for: .revert(commit: repository.changeB), in: repository.path)
        #expect(ready == "Revert \"Change b\"\n\nThis reverts commit \(repository.changeB.hex).")

        try await repository.session.abort(.revert(commit: repository.changeB), in: repository.path)
        #expect(try await repository.session.stoppedWork(in: repository.path) == nil)
        #expect(try await id("HEAD", in: repository.path) == head)
        #expect(try read("f.txt", in: repository.path) == "a\nQ\nc\nd\n")
    }

    @Test func aRevertInALinkedWorktreeIsItsOwn() async throws {
        let repository = try await makeRepository()
        let linked = repository.path + "-linked"
        try await runGit("worktree", "add", "--quiet", "-b", "linked", linked, "HEAD", in: repository.path)
        let revert = try await repository.session.prepareToRevert(repository.changeB, in: linked)
        #expect(try await repository.session.revert(revert, .leavingUncommitted, in: linked) == .leftUncommitted)
        #expect(try await repository.session.stoppedWork(in: linked) == .revert(commit: repository.changeB))
        #expect(await repository.session.stoppedWorkFromFiles(in: linked) == .revert(commit: repository.changeB))
        #expect(try await repository.session.stoppedWork(in: repository.path) == nil)
    }
}
