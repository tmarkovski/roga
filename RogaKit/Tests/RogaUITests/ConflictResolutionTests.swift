import AgentEngine
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
        #expect(work.document?.conflictBands.map(\.conflict) == [0])
        #expect(work.changes.conflictResolve != nil)
    }

    @Test func choosingASideWritesItAndUndoPutsTheConflictBack() async throws {
        let work = try await merging()
        let conflicted = try work.read("a.txt")
        work.changes.resolve(.choose(0, .theirs))
        await work.settled()
        #expect(try work.read("a.txt") == "one\nTHEIRS\nthree\n")
        #expect(work.summary?.left == 0)
        #expect(work.document?.conflictBands.first?.kept == "Kept other's")
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
        #expect(work.document?.conflictBands.first?.kept == "Kept what you wrote")
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

    // MARK: Asking an agent

    func setup() -> GenerationSetup {
        GenerationSetup(
            kind: .claude,
            agent: CommitMessageAgent(kind: .claude, executable: "/usr/local/bin/claude"),
            programs: Programs(searchPath: "/usr/bin"),
            style: "",
            matchesStyle: false,
            label: "Claude Code"
        )
    }

    /// An agent that answers with Claude Code's JSON around `reply`, after `delay`.
    func agent(_ reply: String, delay: Duration = .zero) -> @Sendable (ProgramCommand, [UInt8]) async throws -> ProgramResult {
        { _, _ in
            try await Task.sleep(for: delay)
            let json = #"{"type":"result","is_error":false,"result":\#(String(reflecting: reply))}"#
            return ProgramResult(status: .exited(0), output: Array(json.utf8), errorOutput: "", duration: .seconds(9))
        }
    }

    func settledAgent(_ work: Worktree) async {
        for _ in 0..<200 where work.changes.agentWork["a.txt"]?.isWorking == true {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await work.settled()
    }

    @Test func anAgentsLinesAreWrittenForYouToReadOver() async throws {
        let work = try await merging()
        work.changes.runAgent = agent("<why>Both changed line two, so both stay.</why>\n<conflict n=\"1\">\nOURS\nTHEIRS\n</conflict>")
        work.changes.askAgent(setup())
        #expect(work.changes.agentWork["a.txt"]?.isWorking == true)
        await settledAgent(work)
        #expect(try work.read("a.txt") == "one\nOURS\nTHEIRS\nthree\n")
        #expect(work.changes.agentWork["a.txt"]?.phase == .done(explanation: "Both changed line two, so both stay.", resolved: 1, duration: .seconds(9)))
        #expect(work.document?.conflictBands.first?.kept == "Claude Code wrote this")
        // It isn't marked resolved until someone says so.
        #expect(work.changes.loaded?.conflicted.map(\.path) == ["a.txt"])

        work.changes.resolve(.showSides(0, true))
        await work.settled()
        #expect(work.rows.contains("OURS"))
        #expect(work.rows.contains { $0.hasPrefix("other") })
        #expect(try work.read("a.txt") == "one\nOURS\nTHEIRS\nthree\n")

        work.changes.putConflictsBack(in: try #require(work.selectedFile.file))
        await work.settled()
        #expect(try work.read("a.txt").contains("<<<<<<< HEAD"))
        #expect(work.changes.agentWork["a.txt"] == nil)
        #expect(work.summary?.left == 1)
    }

    @Test func anAgentThatAnswersNothingSaysSo() async throws {
        let work = try await merging()
        let conflicted = try work.read("a.txt")
        work.changes.runAgent = agent("Better not.")
        work.changes.askAgent(setup())
        await settledAgent(work)
        guard case .failed(let message, _) = work.changes.agentWork["a.txt"]?.phase else {
            Issue.record("Expected a failure")
            return
        }
        #expect(message == "Claude Code replied without resolving any of the conflicts.")
        #expect(try work.read("a.txt") == conflicted)
    }

    @Test func stoppingTheAgentChangesNothing() async throws {
        let work = try await merging()
        let conflicted = try work.read("a.txt")
        work.changes.runAgent = agent("<conflict n=\"1\">\nx\n</conflict>", delay: .seconds(30))
        work.changes.askAgent(setup())
        work.changes.stopAgent(for: "a.txt")
        await work.settled()
        #expect(work.changes.agentWork["a.txt"] == nil)
        #expect(try work.read("a.txt") == conflicted)
    }

    @Test func putsBackConflictsResolvedOutsideRoga() async throws {
        let work = try await merging()
        try work.write("one\nedited by hand\nthree\n", to: "a.txt")
        work.changes.refresh()
        await work.settled()
        work.changes.putConflictsBack(in: try #require(work.selectedFile.file))
        await work.settled()
        #expect(try work.read("a.txt").contains("<<<<<<< ours"))
    }

    @Test func sendsAFewLinesAroundEachConflictButNotTheNextOne() throws {
        let numbers = (1...20).map { "\($0)\n" }.joined()
        let conflict = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other\n"
        let file = ConflictedFile.parse(Array((numbers + conflict + "x\n" + conflict + numbers).utf8))
        let first = SelectedChanges.agentConflict(0, of: file)
        #expect(first.before == (13...20).map { "\($0)\n" }.joined())
        #expect(first.ours == "ours\n")
        #expect(first.after == "x\n")
        let second = SelectedChanges.agentConflict(1, of: file)
        #expect(second.before == "x\n")
        #expect(second.after == (1...8).map { "\($0)\n" }.joined())
        let top = SelectedChanges.agentConflict(0, of: ConflictedFile.parse(Array(conflict.utf8)))
        #expect(top.before.isEmpty && top.after.isEmpty)
    }
}
