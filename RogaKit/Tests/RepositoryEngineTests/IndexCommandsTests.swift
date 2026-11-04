import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Staging, unstaging and committing, against real git.
@Suite(.timeLimit(.minutes(1)))
struct IndexCommandsTests {
    func makeRepository(files: [String: String] = ["a.txt": "one\ntwo\n"]) async throws -> (RepositorySession, String) {
        let repository = try makeTemporaryFolder() + "/repository"
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--initial-branch=main", in: repository)
        try await runGit("config", "user.name", "Ana", in: repository)
        try await runGit("config", "user.email", "ana@example.com", in: repository)
        for (path, text) in files {
            try write(text, to: path, in: repository)
        }
        if !files.isEmpty {
            try await runGit("add", "--all", in: repository)
            try await runGit("commit", "--quiet", "--message=First", in: repository)
        }
        return (try await openSession(repository), repository)
    }

    func write(_ text: String, to path: String, in repository: String) throws {
        let file = URL(filePath: repository + "/" + path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func paths(_ files: [DiffFile]) -> [String] {
        files.map(\.path)
    }

    /// A hook that fails with what someone would see, or does whatever `script` says.
    func addHook(_ name: String, script: String, in repository: String) throws {
        let path = repository + "/.git/hooks/" + name
        try FileManager.default.createDirectory(atPath: repository + "/.git/hooks", withIntermediateDirectories: true)
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: URL(filePath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    func message(_ repository: String, of revision: String = "HEAD") async throws -> String {
        try await TestGit.make().text(GitCommand("log", "-1", "--format=%B", revision, in: repository))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Staging

    @Test func stagesAChangedFile() async throws {
        let (session, repository) = try await makeRepository()
        try write("one\ntwo\nthree\n", to: "a.txt", in: repository)
        let before = try await session.status(in: repository)
        try await session.stage(before.unstaged, in: repository)
        let after = try await session.changes(in: repository)
        #expect(paths(after.staged) == ["a.txt"])
        #expect(after.unstaged.isEmpty)
        #expect(after.staged.first?.lines == .init(added: 1, removed: 0))
    }

    @Test func stagesANewFileAndADeletedOne() async throws {
        let (session, repository) = try await makeRepository(files: ["gone.txt": "gone\n", "kept.txt": "kept\n"])
        try FileManager.default.removeItem(atPath: repository + "/gone.txt")
        try write("new\n", to: "folder/new.txt", in: repository)
        let before = try await session.status(in: repository)
        #expect(paths(before.untracked) == ["folder/new.txt"])
        try await session.stage(before.unstaged + before.untracked, in: repository)
        let after = try await session.status(in: repository)
        #expect(after.unstaged.isEmpty && after.untracked.isEmpty)
        #expect(after.staged.map(\.status.letter).sorted() == ["A", "D"])
    }

    @Test func treatsAFilesNameAsItsName() async throws {
        let (session, repository) = try await makeRepository()
        for name in ["*.txt", ":(top)a.txt", "with space.txt", "čćž.txt", "-dash.txt"] {
            try write("text\n", to: name, in: repository)
        }
        let before = try await session.status(in: repository)
        let star = try #require(before.untracked.first { $0.path == "*.txt" })
        try await session.stage([star], in: repository)
        // A pattern would have taken every other file too.
        #expect(paths(try await session.status(in: repository).staged) == ["*.txt"])
        try await session.stage(before.untracked, in: repository)
        #expect(try await session.status(in: repository).untracked.isEmpty)
        try await session.unstage(try await session.status(in: repository).staged, in: repository)
        #expect(try await session.status(in: repository).staged.isEmpty)
    }

    @Test func stagesEverything() async throws {
        let (session, repository) = try await makeRepository()
        try write("changed\n", to: "a.txt", in: repository)
        try write("new\n", to: "new.txt", in: repository)
        try await session.stageEverything(in: repository)
        let after = try await session.status(in: repository)
        #expect(paths(after.staged).sorted() == ["a.txt", "new.txt"])
        #expect(after.unstaged.isEmpty && after.untracked.isEmpty)
    }

    @Test func stagingAConflictMarksItResolved() async throws {
        let (session, repository) = try await makeRepository()
        try await runGit("switch", "--quiet", "-c", "other", in: repository)
        try write("theirs\n", to: "a.txt", in: repository)
        try await runGit("commit", "--quiet", "--all", "--message=Theirs", in: repository)
        try await runGit("switch", "--quiet", "main", in: repository)
        try write("ours\n", to: "a.txt", in: repository)
        try await runGit("commit", "--quiet", "--all", "--message=Ours", in: repository)
        var merge = GitCommand("merge", "other", in: repository)
        merge.successStatuses = [1]
        _ = try await TestGit.make().run(merge)
        let before = try await session.status(in: repository)
        #expect(paths(before.conflicted) == ["a.txt"])
        try write("both\n", to: "a.txt", in: repository)
        try await session.stage(before.conflicted, in: repository)
        let after = try await session.status(in: repository)
        #expect(after.conflicted.isEmpty)
        #expect(paths(after.staged) == ["a.txt"])
        #expect(try await session.message(for: .merge, in: repository)?.hasPrefix("Merge branch 'other'") == true)
    }

    // MARK: Unstaging

    @Test func unstagingLeavesTheFileAsItIs() async throws {
        let (session, repository) = try await makeRepository()
        try write("staged\n", to: "a.txt", in: repository)
        try await runGit("add", "a.txt", in: repository)
        try await session.unstage(try await session.status(in: repository).staged, in: repository)
        let after = try await session.status(in: repository)
        #expect(after.staged.isEmpty)
        #expect(paths(after.unstaged) == ["a.txt"])
        #expect(try String(contentsOfFile: repository + "/a.txt", encoding: .utf8) == "staged\n")
    }

    @Test func unstagingAMovedFileTakesBackWhereItCameFrom() async throws {
        let (session, repository) = try await makeRepository(files: ["old.txt": (1...40).map { "line \($0)\n" }.joined()])
        try await runGit("mv", "old.txt", "new.txt", in: repository)
        let staged = try await session.status(in: repository).staged
        #expect(staged.first?.oldPath == "old.txt")
        try await session.unstage(staged, in: repository)
        let after = try await session.status(in: repository)
        #expect(after.staged.isEmpty)
        #expect(paths(after.unstaged) == ["old.txt"])
        #expect(paths(after.untracked) == ["new.txt"])
    }

    @Test func unstagesBeforeTheFirstCommit() async throws {
        let (session, repository) = try await makeRepository(files: [:])
        try write("new\n", to: "new.txt", in: repository)
        try await runGit("add", "new.txt", in: repository)
        try await session.unstage(try await session.status(in: repository).staged, in: repository)
        let after = try await session.status(in: repository)
        #expect(after.staged.isEmpty)
        #expect(paths(after.untracked) == ["new.txt"])
    }

    // MARK: The index lock

    @Test func waitsForAnotherGitToLetGoOfTheIndex() async throws {
        let (session, repository) = try await makeRepository()
        try write("changed\n", to: "a.txt", in: repository)
        let files = try await session.status(in: repository).unstaged
        let lock = repository + "/.git/index.lock"
        FileManager.default.createFile(atPath: lock, contents: nil)
        let release = Task {
            try await Task.sleep(for: .milliseconds(400))
            try FileManager.default.removeItem(atPath: lock)
        }
        try await session.stage(files, in: repository)
        try await release.value
        #expect(paths(try await session.status(in: repository).staged) == ["a.txt"])
    }

    @Test func givesUpOnALockThatStaysAndSaysWhy() async throws {
        let (session, repository) = try await makeRepository()
        try write("changed\n", to: "a.txt", in: repository)
        let files = try await session.status(in: repository).unstaged
        FileManager.default.createFile(atPath: repository + "/.git/index.lock", contents: nil)
        await #expect {
            try await session.stage(files, in: repository)
        } throws: { error in
            (error as? GitError)?.message.contains("index.lock") == true
        }
    }

    // MARK: Committing

    @Test func commitsWhatsStagedAndLeavesTheRest() async throws {
        let (session, repository) = try await makeRepository(files: ["a.txt": "a\n", "b.txt": "b\n"])
        try write("changed\n", to: "a.txt", in: repository)
        try write("changed\n", to: "b.txt", in: repository)
        try await runGit("add", "a.txt", in: repository)
        let before = try await session.status(in: repository).head
        let made = try await session.commit(CommitRequest(message: "Change a\n\nOnly a, and not b.\n"), in: repository)
        #expect(made.previous == before)
        #expect(made.id != before)
        let after = try await session.status(in: repository)
        #expect(after.head == made.id)
        #expect(after.staged.isEmpty)
        #expect(paths(after.unstaged) == ["b.txt"])
        #expect(try await message(repository) == "Change a\n\nOnly a, and not b.")
    }

    @Test func keepsLinesThatLookLikeComments() async throws {
        let (session, repository) = try await makeRepository()
        try write("changed\n", to: "a.txt", in: repository)
        try await runGit("add", "a.txt", in: repository)
        _ = try await session.commit(CommitRequest(message: "Fix the parser\n\n#123 was about this\n"), in: repository)
        #expect(try await message(repository) == "Fix the parser\n\n#123 was about this")
    }

    @Test func makesTheFirstCommit() async throws {
        let (session, repository) = try await makeRepository(files: [:])
        try write("new\n", to: "new.txt", in: repository)
        try await runGit("add", "new.txt", in: repository)
        let made = try await session.commit(CommitRequest(message: "First"), in: repository)
        #expect(made.previous == nil)
        #expect(try await session.status(in: repository).head == made.id)
    }

    @Test func amendsAndUndoesTheAmend() async throws {
        let (session, repository) = try await makeRepository()
        let first = try #require(try await session.status(in: repository).head)
        try write("more\n", to: "a.txt", in: repository)
        try await runGit("add", "a.txt", in: repository)
        let made = try await session.commit(CommitRequest(message: "Better", amends: true), in: repository)
        #expect(made.previous == first)
        #expect(try await message(repository) == "Better")
        #expect(try await TestGit.make().text(GitCommand("rev-list", "--count", "HEAD", in: repository)) == "1")

        try await session.undo(made, in: repository)
        let after = try await session.status(in: repository)
        #expect(after.head == first)
        #expect(paths(after.staged) == ["a.txt"])
    }

    @Test func aFailedHookLeavesEverythingAndSaysWhatItPrinted() async throws {
        let (session, repository) = try await makeRepository()
        try write("changed\n", to: "a.txt", in: repository)
        try await runGit("add", "a.txt", in: repository)
        let head = try await session.status(in: repository).head
        try addHook("pre-commit", script: "echo 'line 52 is too long'\nexit 1", in: repository)
        await #expect {
            _ = try await session.commit(CommitRequest(message: "Change"), in: repository)
        } throws: { error in
            (error as? GitError)?.message.contains("line 52 is too long") == true
        }
        let after = try await session.status(in: repository)
        #expect(after.head == head)
        #expect(paths(after.staged) == ["a.txt"])

        let made = try await session.commit(CommitRequest(message: "Change", skipsHooks: true), in: repository)
        #expect(try await session.status(in: repository).head == made.id)
    }

    @Test func stoppingAHookLeavesNoCommitAndNoLock() async throws {
        let (session, repository) = try await makeRepository()
        try write("changed\n", to: "a.txt", in: repository)
        try await runGit("add", "a.txt", in: repository)
        let head = try await session.status(in: repository).head
        try addHook("pre-commit", script: "sleep 30", in: repository)
        let commit = Task { try await session.commit(CommitRequest(message: "Change"), in: repository) }
        try await Task.sleep(for: .milliseconds(300))
        commit.cancel()
        _ = await commit.result
        #expect(try await session.status(in: repository).head == head)
        // Nothing stands in the way of the next try.
        try FileManager.default.removeItem(atPath: repository + "/.git/hooks/pre-commit")
        _ = try await session.commit(CommitRequest(message: "Change"), in: repository)
    }

    @Test func undoingAFirstCommitIsnt() async throws {
        let (session, repository) = try await makeRepository(files: [:])
        try write("new\n", to: "new.txt", in: repository)
        try await runGit("add", "new.txt", in: repository)
        let made = try await session.commit(CommitRequest(message: "First"), in: repository)
        await #expect(throws: HeadMoved.self) { try await session.undo(made, in: repository) }
    }

    @Test func wontUndoOnceHeadHasMovedOn() async throws {
        let (session, repository) = try await makeRepository()
        try write("mine\n", to: "a.txt", in: repository)
        try await runGit("add", "a.txt", in: repository)
        let made = try await session.commit(CommitRequest(message: "Mine"), in: repository)
        // An agent commits on top of it.
        try write("theirs\n", to: "a.txt", in: repository)
        try await runGit("commit", "--quiet", "--all", "--message=Theirs", in: repository)
        let agents = try await session.status(in: repository).head
        await #expect(throws: HeadMoved.self) { try await session.undo(made, in: repository) }
        #expect(try await session.status(in: repository).head == agents)
    }

    // MARK: Going on with a rebase

    @Test func continuesARebaseWithItsMessage() async throws {
        let (session, repository) = try await makeRepository()
        try await runGit("switch", "--quiet", "-c", "work", in: repository)
        try write("work\n", to: "a.txt", in: repository)
        try await runGit("commit", "--quiet", "--all", "--message=Work on a", in: repository)
        try await runGit("switch", "--quiet", "main", in: repository)
        try write("main\n", to: "a.txt", in: repository)
        try await runGit("commit", "--quiet", "--all", "--message=Main on a", in: repository)
        try await runGit("switch", "--quiet", "work", in: repository)
        var rebase = GitCommand("rebase", "main", in: repository)
        rebase.successStatuses = [1]
        _ = try await TestGit.make().run(rebase)
        let work = try #require(try await session.stoppedWork(in: repository))
        #expect(try await session.message(for: work, in: repository) == "Work on a")
        try write("both\n", to: "a.txt", in: repository)
        try await session.stage(try await session.status(in: repository).conflicted, in: repository)
        try await session.continueRebase(in: repository)
        #expect(try await session.stoppedWork(in: repository) == nil)
        #expect(try await message(repository) == "Work on a")
    }
}
