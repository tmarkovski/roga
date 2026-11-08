import AgentEngine
import Foundation
import GitRunner
import Observation
import RepositoryEngine

/// Asking an agent what to do about something git refused, and running what it
/// suggests once someone has pressed Run (decision 63).
@Observable
final class GitFixModel {
    /// A suggested command that git refused.
    struct RefusedCommand {
        /// What ran, by its arguments after `git`.
        var command: [String]
        /// What git said about it.
        var said: String
        /// How many commands after it didn't run.
        var skipped: Int
    }

    enum Phase {
        /// Roga is gathering the facts, or the agent is working on them.
        case asking(kind: AgentKind, program: ProgramCommand, showsPath: Bool)
        /// The agent has answered, and nothing has run.
        case answered(kind: AgentKind, fix: AgentGitFix)
        /// The commands are running.
        case running(kind: AgentKind, fix: AgentGitFix)
        /// The commands have run, or stopped at the one that was refused.
        case finished(lines: [TerminalLine], count: Int, refused: RefusedCommand?)
        /// The agent couldn't answer.
        case failed(kind: AgentKind, message: String, output: String?)
    }

    /// What the agent is being asked about.
    private struct Question {
        var setup: GenerationSetup
        var command: [String]
        var said: String
        var attempts: [GitFixRequest.Attempt] = []
    }

    private(set) var phase: Phase?

    @ObservationIgnored private let session: RepositorySession
    @ObservationIgnored private let worktree: String
    @ObservationIgnored private var question: Question?
    /// What's running, which Stop cancels and tests wait for.
    @ObservationIgnored private(set) var work: Task<Void, Never>?
    /// Looks at the repository again, once the commands have run.
    @ObservationIgnored var lookAgain: () -> Void = {}
    /// Runs an agent's command with its standard input, which tests replace.
    @ObservationIgnored var runAgent: (@Sendable (ProgramCommand, [UInt8]) async throws -> ProgramResult)?

    init(session: RepositorySession, worktree: String) {
        self.session = session
        self.worktree = worktree
    }

    /// What the button that asks the agent again says.
    var askAgainTitle: String? {
        question.map { "Fix with \($0.setup.kind.shortName)" }
    }

    /// Asks the agent Generate runs about what git said.
    func start(command: [String], said: String, with setup: GenerationSetup) {
        guard phase == nil else { return }
        ask(Question(setup: setup, command: command, said: said))
    }

    /// Asks the agent again after git refused what it suggested, and tells it what
    /// was tried and what git said about that.
    func askAgain() {
        guard case .finished(_, _, let refused?) = phase, var question else { return }
        question.attempts.append(.init(command: refused.command, said: refused.said))
        phase = nil
        ask(question)
    }

    private func ask(_ question: Question) {
        self.question = question
        let setup = question.setup
        phase = .asking(kind: setup.kind, program: GitFixWriter.command(for: setup.agent, worktree: worktree), showsPath: setup.showsPath)
        let run = runAgent ?? { [programs = setup.programs] command, input in
            try await programs.run(command, input: input)
        }
        work = Task { [session, worktree] in
            do {
                // What git said about an attempt can name paths that it didn't before.
                let said = ([question.said] + question.attempts.map(\.said)).joined(separator: "\n")
                let facts = await session.factsAboutRefusal(said: said, in: worktree)
                try Task.checkCancellation()
                let request = GitFixRequest(
                    worktree: worktree,
                    command: question.command,
                    said: question.said,
                    facts: facts.map { .init(command: $0.command, output: $0.output) },
                    attempts: question.attempts
                )
                let fix = try await GitFixWriter.propose(request, with: setup.agent, run: run)
                try Task.checkCancellation()
                phase = .answered(kind: setup.kind, fix: fix)
            } catch {
                // Stop has already put things back.
                if error is CancellationError || Task.isCancelled { return }
                phase = .failed(kind: setup.kind, message: String(describing: error), output: (error as? CommitMessageError)?.output)
            }
            work = nil
        }
    }

    /// Runs what the agent suggested, one command after the other, and stops at the
    /// first that fails. Only a person pressing Run calls this.
    func run() {
        guard case .answered(let kind, let fix) = phase, fix.canRun else { return }
        phase = .running(kind: kind, fix: fix)
        work = Task { [session, worktree] in
            var lines: [TerminalLine] = []
            var refused: RefusedCommand?
            for (index, command) in fix.commands.enumerated() {
                if !lines.isEmpty { lines.append(.gap) }
                lines.append(.ran(command.arguments))
                do {
                    let printed = try await session.runProposedCommand(command.arguments, in: worktree)
                    if !printed.isEmpty { lines.append(.output(printed)) }
                } catch {
                    lines.append(.output(error.dialogMessage))
                    refused = RefusedCommand(command: command.arguments, said: error.dialogMessage, skipped: fix.commands.count - index - 1)
                    break
                }
            }
            phase = .finished(lines: lines, count: fix.commands.count, refused: refused)
            work = nil
            lookAgain()
        }
    }

    /// Closes the dialog and stops the agent if it's still working. Commands that
    /// have started are left to finish, so that git isn't stopped partway.
    func dismiss() {
        if case .running = phase { return }
        work?.cancel()
        work = nil
        phase = nil
        question = nil
    }
}
