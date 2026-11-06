import AgentEngine
import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import Synchronization
import TestSupport
import Testing
@testable import RogaUI

/// Generate in the commit box, against real git, with a fake agent in place of
/// running one: what it asks for, what it puts in the box, and what the line
/// under the box offers afterward.
@Suite(.timeLimit(.minutes(1)))
struct MessageGeneratorTests {
    struct Worktree {
        var model: RepositoryModel
        var path: String
        var changes: SelectedChanges { model.selectedChanges }
        var composer: CommitComposer { model.composer }
        var generator: MessageGenerator { model.composer.generator }
    }

    /// What the fake agent was asked, and what it should answer.
    nonisolated final class Agent: Sendable {
        struct Call {
            var command: ProgramCommand
            var input: String
        }

        let calls = Mutex<[Call]>([])
        let wasCancelled = Mutex(false)
        /// What it prints on standard output, and its exit status.
        let reply: Mutex<(output: String, status: Int32)>
        /// Ends when the test lets the agent answer, for an agent that's still
        /// writing while the test does something.
        let gate: AsyncStream<Void>?
        let opener: AsyncStream<Void>.Continuation?

        init(reply: String, status: Int32 = 0, waits: Bool = false) {
            self.reply = Mutex((reply, status))
            if waits {
                let (stream, continuation) = AsyncStream<Void>.makeStream()
                gate = stream
                opener = continuation
            } else {
                gate = nil
                opener = nil
            }
        }

        /// Claude Code's JSON, saying it succeeded with `message`.
        static func claude(_ message: String, waits: Bool = false) -> Agent {
            let data = try! JSONSerialization.data(withJSONObject: ["type": "result", "is_error": false, "result": message])
            return Agent(reply: String(decoding: data, as: UTF8.self), waits: waits)
        }

        func answer() {
            opener?.finish()
        }

        var run: @Sendable (ProgramCommand, [UInt8]) async throws -> ProgramResult {
            { [self] command, input in
                calls.withLock { $0.append(Call(command: command, input: String(decoding: input, as: UTF8.self))) }
                if let gate {
                    for await _ in gate {}
                }
                if Task.isCancelled {
                    wasCancelled.withLock { $0 = true }
                    throw CancellationError()
                }
                let (output, status) = reply.withLock { $0 }
                return ProgramResult(status: .exited(status), output: Array(output.utf8), errorOutput: "", duration: .milliseconds(3400))
            }
        }
    }

    /// The drafts a worktree saved, kept in memory.
    nonisolated final class Drafts: Sendable {
        let saved = Mutex<[String: String]>([:])

        @MainActor var drafts: CommitDrafts {
            CommitDrafts { [self] worktree in
                saved.withLock { $0[worktree] ?? "" }
            } write: { [self] worktree, message in
                saved.withLock { $0[worktree] = message }
            }
        }
    }

    @discardableResult
    func git(_ arguments: String..., in folder: String) async throws -> String {
        try await TestGit.make().text(GitCommand(arguments, in: folder))
    }

    func worktree(drafts: CommitDrafts = .none) async throws -> Worktree {
        let folder = try makeTemporaryFolder()
        let path = folder + "/work"
        try await git("clone", "--quiet", "--no-local", try await Fixture.repository("basic"), path, in: folder)
        try await git("config", "user.name", "T", in: path)
        try await git("config", "user.email", "t@example.com", in: path)
        let session = try await RepositorySession.open(containing: path, git: try await TestGit.make())
        let model = RepositoryModel(session: session, worktree: path, fetchesByItself: { false }, drafts: drafts)
        model.branch.timeToPlayHouse = { _ in .zero }
        model.branch.timeToShowFinished = { _ in .seconds(600) }
        return Worktree(model: model, path: path)
    }

    func write(_ text: String, to path: String, in repository: String) throws {
        try Data(text.utf8).write(to: URL(filePath: repository + "/" + path))
    }

    /// A worktree with the readme changed and staged, its changes' row selected.
    func staged(drafts: CommitDrafts = .none) async throws -> Worktree {
        let work = try await worktree(drafts: drafts)
        try write("Roga\n", to: "README.md", in: work.path)
        try await git("add", "README.md", in: work.path)
        try await open(work)
        return work
    }

    func open(_ work: Worktree) async throws {
        await work.model.appear()
        work.model.selectRow(0)
        await settled(work)
        #expect(work.changes.isSelected)
    }

    func settled(_ work: Worktree) async {
        await work.changes.applyingIndexChanges?.value
        await work.model.branch.running?.value
        await work.composer.readingMessage?.value
        await work.model.check?.value
        await work.model.load()
        await work.changes.applyingIndexChanges?.value
        await work.changes.loading?.value
    }

    func setup(_ kind: AgentKind = .claude, matchesStyle: Bool = true) -> GenerationSetup {
        GenerationSetup(
            kind: kind,
            agent: CommitMessageAgent(kind: kind, executable: "/usr/local/bin/" + kind.rawValue, model: "haiku", effort: "low"),
            programs: Programs(searchPath: "/usr/bin"),
            style: "Keep it short.",
            matchesStyle: matchesStyle,
            label: GenerationSetup.label(kind, model: "haiku")
        )
    }

    /// Whether the agent was stopped. It lets an agent that wasn't stopped
    /// answer, so that a test of code that doesn't stop it fails rather than
    /// waits for ever.
    func wasStopped(_ agent: Agent, running: Task<Void, Never>?) async -> Bool {
        let wasStopped = await AgentTestSupport.eventually(within: .seconds(5)) { agent.wasCancelled.withLock { $0 } }
        agent.answer()
        await running?.value
        return wasStopped
    }

    func generate(_ work: Worktree, with agent: Agent, setup: GenerationSetup? = nil) async {
        work.generator.run = agent.run
        work.generator.generate(with: setup ?? self.setup())
        await work.generator.running?.value
    }

    // MARK: What it asks for

    @Test func writesTheMessageForWhatsStaged() async throws {
        let drafts = Drafts()
        let work = try await staged(drafts: drafts.drafts)
        let agent = Agent.claude("Rename the app in the readme\n\nIt's called Roga now.")
        #expect(work.generator.readiness == .ready)
        await generate(work, with: agent)

        let request = try #require(work.generator.lastRequest)
        #expect(request.worktree == work.path)
        #expect(request.branch == "main")
        #expect(request.draft == nil)
        #expect(request.style == "Keep it short.")
        #expect(request.recentSubjects == ["Change the app", "Add the app", "Add the readme"])
        #expect(request.changes.files.map(\.path) == ["README.md"])
        #expect(request.changes.patch.contains("+Roga"))

        let call = try #require(agent.calls.withLock { $0.first })
        #expect(call.command.executable == "/usr/local/bin/claude")
        #expect(call.command.directory == work.path)
        #expect(call.command.environment["ROGA_GENERATING"] == "1")
        #expect(call.input.contains("+Roga"))
        #expect(call.input.contains("Change the app"))

        #expect(work.composer.message == "Rename the app in the readme\n\nIt's called Roga now.")
        #expect(drafts.saved.withLock { $0[work.path] } == work.composer.message)
        guard case .written(let written) = work.generator.phase else {
            Issue.record("Expected a written message, got \(work.generator.phase)")
            return
        }
        #expect(written.label == "Claude Code · haiku")
        #expect(written.subject == "Rename the app in the readme")
        #expect(!written.stagedFilesChanged)
        #expect(MessageGenerator.writtenWords(written) == "Claude Code · haiku wrote this in 3 s.")
    }

    @Test func startsFromTheWordsInTheBox() async throws {
        let work = try await staged()
        work.composer.message = "readme: new name"
        await generate(work, with: Agent.claude("Rename the app in the readme"))
        #expect(work.generator.lastRequest?.draft == "readme: new name")
        #expect(work.composer.message == "Rename the app in the readme")
    }

    @Test func blankLinesArentADraft() async throws {
        let work = try await staged()
        work.composer.message = "\n  \n"
        await generate(work, with: Agent.claude("Rename the app in the readme"))
        #expect(work.generator.lastRequest?.draft == nil)
    }

    @Test func leavesOutRecentSubjectsWhenNotMatchingTheStyle() async throws {
        let work = try await staged()
        await generate(work, with: Agent.claude("Rename the app"), setup: setup(matchesStyle: false))
        #expect(work.generator.lastRequest?.recentSubjects == [])
    }

    @Test func anAmendDescribesTheCommitItReplaces() async throws {
        let work = try await worktree()
        // Something uncommitted, so that the row is there, but nothing staged.
        try write("notes\n", to: "notes.txt", in: work.path)
        try await open(work)
        #expect(work.generator.readiness == .nothingStaged)
        work.composer.setAmending(true)
        await settled(work)
        #expect(work.composer.message == "Change the app\n\nThe body says why.")
        #expect(work.generator.readiness == .ready)

        await generate(work, with: Agent.claude("Add a second line to the app"))
        let request = try #require(work.generator.lastRequest)
        #expect(request.changes.files.map(\.path) == ["src/app.txt"])
        #expect(request.draft == "Change the app\n\nThe body says why.")
        #expect(work.composer.message == "Add a second line to the app")
        #expect(work.composer.isAmending)
    }

    @Test func doesNothingWithNothingStaged() async throws {
        let work = try await worktree()
        try write("Roga\n", to: "README.md", in: work.path)
        try await open(work)
        #expect(work.generator.readiness == .nothingStaged)
        let agent = Agent.claude("Rename the app")
        await generate(work, with: agent)
        #expect(work.generator.phase == .idle)
        #expect(work.generator.lastRequest == nil)
        #expect(agent.calls.withLock { $0.isEmpty })
    }

    @Test func doesNothingWithoutAnAgent() async throws {
        let work = try await staged()
        work.generator.generate(with: nil)
        #expect(work.generator.phase == .idle)
        #expect(work.generator.running == nil)
    }

    @Test func waitsDuringARebase() async throws {
        let work = try await staged()
        work.composer.worktreeIsPartway(through: .rebase(branch: nil))
        #expect(work.generator.readiness == .busy)
    }

    // MARK: While it writes

    @Test func theBoxWaitsWhileItWrites() async throws {
        let work = try await staged()
        work.composer.message = "my words"
        let agent = Agent.claude("Rename the app", waits: true)
        work.generator.run = agent.run
        work.generator.now = { Date(timeIntervalSince1970: 100) }
        work.generator.generate(with: setup())
        #expect(work.generator.phase == .writing(.init(kind: .claude, since: Date(timeIntervalSince1970: 100))))
        #expect(work.composer.isMessageReadOnly)
        #expect(work.composer.action.isEnabled == false)
        #expect(work.generator.readiness == .busy)
        // Amend would change the message under it.
        work.composer.setAmending(true)
        #expect(!work.composer.isAmending)

        agent.answer()
        await work.generator.running?.value
        #expect(!work.composer.isMessageReadOnly)
        #expect(work.composer.action.isEnabled)
        #expect(work.composer.message == "Rename the app")
    }

    @Test func stopGivesTheBoxBack() async throws {
        let work = try await staged()
        work.composer.message = "my words"
        let agent = Agent.claude("Rename the app", waits: true)
        work.generator.run = agent.run
        work.generator.generate(with: setup())
        #expect(await AgentTestSupport.eventually { agent.calls.withLock { !$0.isEmpty } })
        let running = work.generator.running

        work.generator.stop()
        #expect(work.generator.phase == .idle)
        #expect(work.composer.message == "my words")
        #expect(!work.composer.isMessageReadOnly)
        await running?.value
        #expect(agent.wasCancelled.withLock { $0 })
        // What it would have written never arrives.
        #expect(work.generator.phase == .idle)
        #expect(work.composer.message == "my words")
    }

    @Test func keepsWritingAfterTheWorktreeIsLeft() async throws {
        let work = try await staged()
        let agent = Agent.claude("Rename the app", waits: true)
        work.generator.run = agent.run
        work.generator.generate(with: setup())
        #expect(await AgentTestSupport.eventually { agent.calls.withLock { !$0.isEmpty } })
        work.model.selectRow(1)
        #expect(!work.changes.isSelected)
        agent.answer()
        await work.generator.running?.value
        #expect(work.composer.message == "Rename the app")
        if case .written = work.generator.phase {} else { Issue.record("Expected a written message") }
    }

    @Test func saysWhenTheStagedFilesChangedWhileItWrote() async throws {
        let work = try await staged()
        let agent = Agent.claude("Rename the app", waits: true)
        work.generator.run = agent.run
        work.generator.generate(with: setup())
        #expect(await AgentTestSupport.eventually { agent.calls.withLock { !$0.isEmpty } })
        try write("one\ntwo\nthree\n", to: "src/app.txt", in: work.path)
        try await git("add", "src/app.txt", in: work.path)
        work.changes.refresh()
        await work.changes.loading?.value
        #expect(work.changes.loaded?.staged.count == 2)

        agent.answer()
        await work.generator.running?.value
        guard case .written(let written) = work.generator.phase else {
            Issue.record("Expected a written message")
            return
        }
        #expect(written.stagedFilesChanged)
        #expect(MessageGenerator.writtenWords(written) == "Claude Code · haiku wrote this in 3 s. The staged files changed while it wrote.")
    }

    @Test func stagingRightBeforeIsntAChangeWhileItWrote() async throws {
        let work = try await worktree()
        try write("Roga\n", to: "README.md", in: work.path)
        try await open(work)
        let file = try #require(work.changes.loaded?.unstaged.first { $0.path == "README.md" })
        // Space and then Generate at once: the list is Roga's guess until git's
        // own comes, with the file's blob ID.
        work.changes.toggle(file, in: .unstaged)
        #expect(work.changes.loaded?.staged.first?.newID == nil)
        let agent = Agent.claude("Rename the app", waits: true)
        work.generator.run = agent.run
        work.generator.generate(with: setup())
        #expect(await AgentTestSupport.eventually { agent.calls.withLock { !$0.isEmpty } })
        await settled(work)
        #expect(work.changes.loaded?.staged.first?.newID != nil)

        agent.answer()
        await work.generator.running?.value
        #expect(work.generator.lastRequest?.changes.files.map(\.path) == ["README.md"])
        guard case .written(let written) = work.generator.phase else {
            Issue.record("Expected a written message, got \(work.generator.phase)")
            return
        }
        #expect(!written.stagedFilesChanged)
    }

    @Test func aRebaseStopsItAndTurnsAmendOff() async throws {
        let work = try await worktree()
        try write("notes\n", to: "notes.txt", in: work.path)
        try await open(work)
        work.composer.message = "my draft"
        work.composer.setAmending(true)
        await settled(work)
        let agent = Agent.claude("Add a second line to the app", waits: true)
        work.generator.run = agent.run
        work.generator.generate(with: setup())
        #expect(await AgentTestSupport.eventually { agent.calls.withLock { !$0.isEmpty } })
        let running = work.generator.running

        // A pull that rebases stops partway.
        work.composer.worktreeIsPartway(through: .rebase(branch: nil))
        #expect(work.generator.phase == .idle)
        #expect(!work.composer.isAmending)
        #expect(work.composer.message == "my draft")
        #expect(await wasStopped(agent, running: running))

        work.composer.worktreeIsPartway(through: nil)
        #expect(!work.composer.isAmending)
        #expect(work.composer.heading.lead == "Commit to")
        #expect(work.composer.message == "my draft")
    }

    @Test func aMergeStopsIt() async throws {
        let work = try await staged()
        let agent = Agent.claude("Rename the app", waits: true)
        work.generator.run = agent.run
        work.generator.generate(with: setup())
        #expect(await AgentTestSupport.eventually { agent.calls.withLock { !$0.isEmpty } })
        let running = work.generator.running
        work.composer.worktreeIsPartway(through: .merge)
        #expect(work.generator.phase == .idle)
        #expect(!work.composer.isMessageReadOnly)
        #expect(await wasStopped(agent, running: running))
        #expect(work.composer.message == "")
    }

    @Test func undoingTheCommitStopsItAndBringsTheMessageBack() async throws {
        let work = try await staged()
        work.composer.message = "First"
        work.composer.commit()
        await settled(work)
        #expect(work.composer.lastCommit != nil)
        try write("notes\n", to: "notes.txt", in: work.path)
        try await git("add", "notes.txt", in: work.path)
        await settled(work)
        let agent = Agent.claude("Add notes", waits: true)
        work.generator.run = agent.run
        work.generator.generate(with: setup())
        #expect(await AgentTestSupport.eventually { agent.calls.withLock { !$0.isEmpty } })
        let running = work.generator.running

        work.composer.undoLastCommit()
        await settled(work)
        #expect(work.generator.phase == .idle)
        #expect(work.composer.message == "First")
        #expect(await wasStopped(agent, running: running))
        #expect(work.composer.message == "First")
        // The note's Undo has gone with the note.
        work.generator.undo()
        #expect(work.composer.message == "First")
    }

    // MARK: Afterward

    @Test func undoPutsBackWhatWasThere() async throws {
        let work = try await staged()
        work.composer.message = "my words"
        await generate(work, with: Agent.claude("Rename the app\n\nIt's Roga now."))
        #expect(work.composer.message == "Rename the app\n\nIt's Roga now.")
        work.generator.undo()
        #expect(work.composer.message == "my words")
        #expect(work.generator.phase == .idle)
    }

    @Test func theNoteStaysForTheBodyAndGoesForTheSubject() async throws {
        let work = try await staged()
        await generate(work, with: Agent.claude("Rename the app\n\nIt's Roga now."))
        work.composer.message = "Rename the app\n\nIt's called Roga now."
        if case .written = work.generator.phase {} else { Issue.record("The note went for an edit to the body") }
        work.composer.message = "Rename the app everywhere\n\nIt's called Roga now."
        #expect(work.generator.phase == .idle)
    }

    @Test func theNoteGoesWhenTheBoxIsEmptied() async throws {
        let work = try await staged()
        await generate(work, with: Agent.claude("Rename the app"))
        work.composer.message = ""
        #expect(work.generator.phase == .idle)
    }

    @Test func theNoteGoesOnCommitting() async throws {
        let work = try await staged()
        await generate(work, with: Agent.claude("Rename the app"))
        work.composer.commit()
        #expect(work.generator.phase == .idle)
        await settled(work)
        #expect(try await git("log", "-1", "--format=%s", in: work.path) == "Rename the app")
    }

    @Test func generatingAgainReplacesTheNote() async throws {
        let work = try await staged()
        await generate(work, with: Agent.claude("Rename the app"))
        let agent = Agent.claude("Rename the app in the readme", waits: true)
        work.generator.run = agent.run
        work.generator.generate(with: setup())
        #expect(work.generator.isWriting)
        // It starts from the agent's own words this time.
        agent.answer()
        await work.generator.running?.value
        #expect(work.generator.lastRequest?.draft == "Rename the app")
        work.generator.undo()
        #expect(work.composer.message == "Rename the app")
    }

    @Test func aFailureKeepsTheTextAndSaysWhy() async throws {
        let work = try await staged()
        work.composer.message = "my words"
        let reply = #"{"type":"result","is_error":true,"result":"Failed to authenticate. OAuth session expired and could not be refreshed"}"#
        await generate(work, with: Agent(reply: reply, status: 1))
        #expect(work.composer.message == "my words")
        guard case .failed(let failure) = work.generator.phase else {
            Issue.record("Expected a failure, got \(work.generator.phase)")
            return
        }
        #expect(failure.kind == .claude)
        #expect(failure.message == "Claude Code isn't signed in. Run claude auth login in Terminal.")
        #expect(failure.output == "Failed to authenticate. OAuth session expired and could not be refreshed")
        #expect(MessageGenerator.failureTitle(.claude) == "Claude Code didn't write a message")

        // Typing sends the failure away.
        work.composer.message = "my words, more"
        #expect(work.generator.phase == .idle)
    }

    @Test func aFailureDoesntRepeatItself() async throws {
        let work = try await staged()
        let reply = #"{"type":"result","is_error":true,"result":"Invalid API key · Please run /login"}"#
        await generate(work, with: Agent(reply: reply, status: 1))
        guard case .failed(let failure) = work.generator.phase else {
            Issue.record("Expected a failure, got \(work.generator.phase)")
            return
        }
        #expect(failure.message == "Invalid API key · Please run /login")
        // What it printed is the same sentence, so there's nothing to unfold.
        #expect(failure.output == nil)
    }

    @Test func aFailureToStartSaysSo() async throws {
        let work = try await staged()
        work.generator.run = { command, _ in
            throw ProgramError.timedOut(command, .seconds(60), errorOutput: "")
        }
        work.generator.generate(with: setup(.codex))
        await work.generator.running?.value
        guard case .failed(let failure) = work.generator.phase else {
            Issue.record("Expected a failure")
            return
        }
        #expect(failure.kind == .codex)
        #expect(failure.message == "codex didn't finish within 1 minute, so Roga stopped it.")
        #expect(failure.output == nil)
    }

    // MARK: Words

    @Test func countsTheSecondsWhileItWrites() {
        let start = Date(timeIntervalSince1970: 1000)
        #expect(MessageGenerator.writingWords(.claude, since: start, now: start.addingTimeInterval(0.4)) == "Claude Code is writing…")
        #expect(MessageGenerator.writingWords(.claude, since: start, now: start.addingTimeInterval(3.2)) == "Claude Code is writing… 3 s")
        #expect(MessageGenerator.writingWords(.codex, since: start, now: start.addingTimeInterval(61)) == "Codex is writing… 61 s")
    }

    @Test func roundsTheTimeItTook() {
        func words(_ duration: Duration) -> String {
            MessageGenerator.writtenWords(.init(label: "Codex", duration: duration, stagedFilesChanged: false, subject: "x"))
        }
        #expect(words(.milliseconds(200)) == "Codex wrote this in 1 s.")
        #expect(words(.milliseconds(4400)) == "Codex wrote this in 4 s.")
        #expect(words(.milliseconds(4600)) == "Codex wrote this in 5 s.")
    }
}
