import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Reading conflicts from a worktree's files and resolving them, against real git
/// (decision 60).
@Suite(.timeLimit(.minutes(1)))
struct ConflictCommandsTests {
    /// A repository whose `main` and `other` each changed the second line of
    /// `a.txt`, and added a line to the end of `b.txt`.
    func makeRepository() async throws -> (RepositorySession, String) {
        let repository = try makeTemporaryFolder() + "/repository"
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--initial-branch=main", in: repository)
        try await runGit("config", "user.name", "Ana", in: repository)
        try await runGit("config", "user.email", "ana@example.com", in: repository)
        try write("one\ntwo\nthree\n", to: "a.txt", in: repository)
        try write("first\n", to: "b.txt", in: repository)
        try await runGit("add", "--all", in: repository)
        try await runGit("commit", "--quiet", "--message=First", in: repository)
        try await runGit("switch", "--quiet", "-c", "other", in: repository)
        try write("one\nTHEIRS\nthree\n", to: "a.txt", in: repository)
        try write("first\ntheirs\n", to: "b.txt", in: repository)
        try await runGit("commit", "--quiet", "--all", "--message=Theirs", in: repository)
        try await runGit("switch", "--quiet", "main", in: repository)
        try write("one\nOURS\nthree\n", to: "a.txt", in: repository)
        try write("first\nours\n", to: "b.txt", in: repository)
        try await runGit("commit", "--quiet", "--all", "--message=Ours", in: repository)
        return (try await openSession(repository), repository)
    }

    func write(_ text: String, to path: String, in repository: String) throws {
        try Data(text.utf8).write(to: URL(filePath: repository + "/" + path))
    }

    func read(_ path: String, in repository: String) throws -> String {
        try String(contentsOfFile: repository + "/" + path, encoding: .utf8)
    }

    /// Runs a git command that stops on a conflict, which exits with 1.
    func stop(_ arguments: String..., in repository: String) async throws {
        var command = GitCommand(arguments, in: repository)
        command.successStatuses = [1]
        _ = try await TestGit.make().run(command)
    }

    @Test func readsAMergesConflictsWithTheirLabels() async throws {
        let (session, repository) = try await makeRepository()
        try await stop("merge", "other", in: repository)
        let file = try #require(try await session.conflictedFile("a.txt", in: repository))
        #expect(file.conflicts.count == 1)
        #expect(file.conflicts[0].oursLabel == "HEAD")
        #expect(file.conflicts[0].theirsLabel == "other")
        #expect(String(decoding: file.bytes[file.conflicts[0].ours], as: UTF8.self) == "OURS\n")
        #expect(String(decoding: file.bytes[file.conflicts[0].theirs], as: UTF8.self) == "THEIRS\n")
        #expect(try await session.incomingConflictLabel(in: repository) == (try await runGit("rev-parse", "other", in: repository)))
    }

    @Test func writesAResolutionAndKeepsTheFilesMode() async throws {
        let (session, repository) = try await makeRepository()
        try await stop("merge", "other", in: repository)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repository + "/a.txt")
        let file = try #require(try await session.conflictedFile("a.txt", in: repository))
        try await session.write(file.resolving([0: .both]), replacing: file.bytes, at: "a.txt", in: repository)
        #expect(try read("a.txt", in: repository) == "one\nOURS\nTHEIRS\nthree\n")
        let mode = try FileManager.default.attributesOfItem(atPath: repository + "/a.txt")[.posixPermissions] as? Int
        #expect(mode == 0o755)
        // Writing doesn't mark it resolved. That's for whoever looks at it.
        #expect(try await session.status(in: repository).conflicted.map(\.path) == ["a.txt", "b.txt"])
    }

    @Test func refusesToWriteOverAFileThatChanged() async throws {
        let (session, repository) = try await makeRepository()
        try await stop("merge", "other", in: repository)
        let file = try #require(try await session.conflictedFile("a.txt", in: repository))
        try write("an agent wrote this\n", to: "a.txt", in: repository)
        await #expect(throws: ConflictedFileChanged(path: "a.txt")) {
            try await session.write(file.resolving([0: .ours]), replacing: file.bytes, at: "a.txt", in: repository)
        }
        #expect(try read("a.txt", in: repository) == "an agent wrote this\n")
    }

    @Test func keepsOneSidesVersionAndMarksItResolved() async throws {
        let (session, repository) = try await makeRepository()
        try await stop("merge", "other", in: repository)
        try await session.keep(.theirs, of: "a.txt", in: repository)
        try await session.keep(.ours, of: "b.txt", in: repository)
        #expect(try read("a.txt", in: repository) == "one\nTHEIRS\nthree\n")
        #expect(try read("b.txt", in: repository) == "first\nours\n")
        let status = try await session.status(in: repository)
        #expect(status.conflicted.isEmpty)
        #expect(status.staged.map(\.path) == ["a.txt"])
    }

    @Test func putsConflictsBackAsGitWroteThem() async throws {
        let (session, repository) = try await makeRepository()
        try await stop("merge", "other", in: repository)
        let before = try read("a.txt", in: repository)
        try write("one\nresolved\nthree\n", to: "a.txt", in: repository)
        try await session.putConflictsBack(in: "a.txt", in: repository)
        let file = try #require(try await session.conflictedFile("a.txt", in: repository))
        #expect(file.conflicts.count == 1)
        #expect(try read("a.txt", in: repository).contains("OURS\n=======\nTHEIRS"))
        #expect(!before.isEmpty)
    }

    @Test func labelsARevertsSideAsTheParentOfTheCommit() async throws {
        let (session, repository) = try await makeRepository()
        try write("one\nLATER\nthree\n", to: "a.txt", in: repository)
        try await runGit("commit", "--quiet", "--all", "--message=Later", in: repository)
        let ours = try await runGit("rev-parse", "HEAD~1", in: repository)
        try await stop("revert", "--no-edit", "HEAD~1", in: repository)
        let file = try #require(try await session.conflictedFile("a.txt", in: repository))
        #expect(file.conflicts[0].theirsLabel.hasPrefix("parent of " + ours.prefix(7)))
        #expect(try await session.incomingConflictLabel(in: repository) == "parent of " + ours)
    }

    @Test func labelsAStashPopsSides() async throws {
        let (session, repository) = try await makeRepository()
        try write("one\nMINE\nthree\n", to: "a.txt", in: repository)
        try await runGit("stash", "push", "--quiet", in: repository)
        try write("one\nCOMMITTED\nthree\n", to: "a.txt", in: repository)
        try await runGit("commit", "--quiet", "--all", "--message=Committed", in: repository)
        try await stop("stash", "pop", in: repository)
        let file = try #require(try await session.conflictedFile("a.txt", in: repository))
        #expect(file.conflicts[0].oursLabel == "Updated upstream")
        #expect(file.conflicts[0].theirsLabel == "Stashed changes")
        #expect(try await session.incomingConflictLabel(in: repository) == "Stashed changes")
    }

    @Test func findsWhatARebaseIsGoingOnto() async throws {
        let (session, repository) = try await makeRepository()
        let onto = try await runGit("rev-parse", "other", in: repository)
        #expect(try await session.rebaseOnto(in: repository) == nil)
        try await stop("rebase", "other", in: repository)
        #expect(try await session.rebaseOnto(in: repository) == ObjectID(hex: onto))
        let file = try #require(try await session.conflictedFile("a.txt", in: repository))
        #expect(file.conflicts[0].oursLabel == "HEAD")
        #expect(file.conflicts[0].theirsLabel.hasSuffix("(Ours)"))
    }

    @Test func readsNothingFromALinkOrAFolder() async throws {
        let (session, repository) = try await makeRepository()
        try FileManager.default.createSymbolicLink(atPath: repository + "/link", withDestinationPath: "a.txt")
        try FileManager.default.createDirectory(atPath: repository + "/folder", withIntermediateDirectories: true)
        #expect(try await session.conflictedFile("link", in: repository) == nil)
        #expect(try await session.conflictedFile("folder", in: repository) == nil)
    }
}
