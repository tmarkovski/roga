import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import TestSupport
import Testing
@testable import DiffUI
@testable import RogaUI

/// Resolving conflicts in the panels, against real git (decision 60).
@Suite(.timeLimit(.minutes(1)))
struct ConflictResolutionTests {
    struct Worktree {
        var model: RepositoryModel
        var path: String
        var changes: SelectedChanges { model.selectedChanges }
        var selectedFile: SelectedFile { model.selectedFile }

        func read(_ file: String) throws -> String {
            try String(contentsOfFile: path + "/" + file, encoding: .utf8)
        }

        func write(_ text: String, to file: String) throws {
            try Data(text.utf8).write(to: URL(filePath: path + "/" + file))
        }

        func git(_ arguments: String..., stops: Bool = false) async throws {
            var command = GitCommand(arguments, in: path)
            if stops { command.successStatuses = [1] }
            _ = try await TestGit.make().run(command)
        }

        func settled() async {
            await changes.resolving?.value
            await changes.applyingIndexChanges?.value
            await model.check?.value
            await changes.loading?.value
            await selectedFile.loading?.value
        }

        func open() async {
            await model.appear()
            model.selectRow(0)
            await settled()
        }

        var summary: ConflictSummary? { selectedFile.shown?.conflicts }

        var document: DiffDocument? {
            if case .patch(let document) = selectedFile.shown?.content { document } else { nil }
        }

        /// What the diff panel shows, one row a line.
        var rows: [String] {
            document?.storage.string.split(separator: "\n").map(String.init) ?? []
        }
    }

    /// A worktree on `main` partway through merging `other`, which changed the
    /// same line of `a.txt`.
    func merging() async throws -> Worktree {
        let path = try makeTemporaryFolder() + "/work"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let git = try await TestGit.make()
        func run(_ arguments: String...) async throws {
            _ = try await git.run(GitCommand(arguments, in: path))
        }
        func write(_ text: String) throws {
            try Data(text.utf8).write(to: URL(filePath: path + "/a.txt"))
        }
        try await run("init", "--quiet", "--initial-branch=main")
        try await run("config", "user.name", "T")
        try await run("config", "user.email", "t@example.com")
        try write("one\ntwo\nthree\n")
        try await run("add", "a.txt")
        try await run("commit", "--quiet", "--message=First")
        try await run("switch", "--quiet", "-c", "other")
        try write("one\nTHEIRS\nthree\n")
        try await run("commit", "--quiet", "--all", "--message=Theirs")
        try await run("switch", "--quiet", "main")
        try write("one\nOURS\nthree\n")
        try await run("commit", "--quiet", "--all", "--message=Ours")
        let session = try await RepositorySession.open(containing: path, git: git)
        let model = RepositoryModel(session: session, worktree: path, fetchesByItself: { false }, drafts: .none)
        let worktree = Worktree(model: model, path: path)
        try await worktree.git("merge", "other", stops: true)
        await worktree.open()
        return worktree
    }

    @Test func showsAConflictedFilesConflictsWithItsSidesNamed() async throws {
        let work = try await merging()
        #expect(work.selectedFile.group == .conflicted)
        #expect(work.summary?.total == 1)
        #expect(work.summary?.left == 1)
        #expect(work.summary?.sides.ours.name == "main")
        #expect(work.summary?.sides.ours.detail.hasSuffix("· Ours") == true)
        #expect(work.summary?.sides.theirs.name == "other")
        #expect(work.document?.hasConflicts == true)
        #expect(work.rows.contains("Conflict 1 of 1"))
        #expect(work.changes.conflictResolve != nil)
    }

    @Test func choosingASideWritesItAndUndoPutsTheConflictBack() async throws {
        let work = try await merging()
        let conflicted = try work.read("a.txt")
        work.changes.resolve(.choose(0, .theirs))
        await work.settled()
        #expect(try work.read("a.txt") == "one\nTHEIRS\nthree\n")
        #expect(work.summary?.left == 0)
        #expect(work.rows.contains("Conflict 1 of 1 · Kept other's"))
        // Writing isn't marking it resolved.
        #expect(work.changes.loaded?.conflicted.map(\.path) == ["a.txt"])

        work.changes.resolve(.undo(0))
        await work.settled()
        #expect(try work.read("a.txt") == conflicted)
        #expect(work.summary?.left == 1)
    }

    @Test func linesWrittenByHandReplaceTheConflict() async throws {
        let work = try await merging()
        work.changes.resolve(.choose(0, .lines(ConflictedFile.lines(typed: "OURS and THEIRS"))))
        await work.settled()
        #expect(try work.read("a.txt") == "one\nOURS and THEIRS\nthree\n")
        #expect(work.rows.contains("Conflict 1 of 1 · Kept what you wrote"))
    }

    @Test func aFileThatChangedMeanwhileIsntWrittenOver() async throws {
        let work = try await merging()
        try work.write("<<<<<<< HEAD\nan agent\n=======\nwrote this\n>>>>>>> other\n", to: "a.txt")
        work.changes.resolve(.choose(0, .ours))
        await work.settled()
        #expect(try work.read("a.txt") == "<<<<<<< HEAD\nan agent\n=======\nwrote this\n>>>>>>> other\n")
        #expect(work.model.branch.failure?.title == "Can't resolve the conflict in a.txt")
        // It shows the file as it is now.
        #expect(work.rows.contains("an agent"))
    }

    @Test func markingItResolvedStagesItAndForgetsWhatWasChosen() async throws {
        let work = try await merging()
        work.changes.resolve(.choose(0, .both))
        await work.settled()
        let file = try #require(work.changes.loaded?.conflicted.first)
        work.changes.toggle(file, in: .conflicted)
        await work.settled()
        #expect(work.changes.conflicts.progress(of: "a.txt") == nil)
        #expect(work.changes.loaded?.conflicted.isEmpty == true)
        #expect(work.changes.loaded?.staged.map(\.path) == ["a.txt"])
        #expect(try work.read("a.txt") == "one\nOURS\nTHEIRS\nthree\n")
    }

    @Test func keepingAVersionTakesTheWholeFileAndMarksItResolved() async throws {
        let work = try await merging()
        let file = try #require(work.changes.loaded?.conflicted.first)
        work.changes.keep(.theirs, of: file)
        await work.settled()
        await work.settled()
        #expect(try work.read("a.txt") == "one\nTHEIRS\nthree\n")
        #expect(work.changes.loaded?.conflicted.isEmpty == true)
    }
}
