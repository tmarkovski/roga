import AgentEngine
import AppKit
import Foundation
import GitCore
import GitRunner
import Observation
import RepositoryEngine

/// Has an agent write the message of a worktree's next commit from what's
/// staged, for the Generate button in the commit box (decision 41).
///
/// It belongs to the worktree's `CommitComposer`. Its run is a task of its own
/// rather than a view's, so leaving the worktree doesn't stop the agent, and the
/// message is in the box, saved as the draft, on coming back. A box made for
/// the worktree again while the agent writes takes it over from the one that
/// started it, through `MessageGenerators`.
@Observable
final class MessageGenerator {
    enum Phase: Equatable {
        case idle
        /// An agent is writing, and the box waits for it, read-only.
        case writing(Writing)
        /// An agent wrote what's in the box, which Undo can take back.
        case written(Written)
        /// The agent didn't write a message, so what was in the box stays.
        case failed(Failure)
    }

    struct Writing: Equatable {
        var kind: AgentKind
        /// When it started, which the box counts the seconds from.
        var since: Date
    }

    struct Written: Equatable {
        /// The agent and its model, as in "Claude Code · haiku".
        var label: String
        /// How long the agent took.
        var duration: Duration
        /// Whether the staged files changed while the agent wrote, so that the
        /// message may not describe what's staged now.
        var stagedFilesChanged: Bool
        /// The first line it wrote. Changing that line sends the note away,
        /// since the message is then the author's rather than the agent's.
        var subject: String
    }

    struct Failure: Equatable {
        var kind: AgentKind
        /// What went wrong in one sentence, in the error's own words.
        var message: String
        /// What the agent printed, when there's more to see than the message.
        var output: String?
    }

    /// Whether Generate can run now.
    enum Readiness: Equatable {
        case ready
        /// Nothing's staged and the commit isn't an amend, so there's nothing
        /// to describe yet.
        case nothingStaged
        /// A rebase has stopped, and the box shows the message of the commit
        /// it stopped on, which isn't the agent's to write.
        case rebasing
        /// The box is busy committing or writing already, Amend hasn't put the
        /// commit's message in it yet, or the files haven't been listed yet.
        case busy
    }

    private(set) var phase = Phase.idle

    /// What runs the agent, which tests replace. Without it, the setup's own
    /// programs run it.
    @ObservationIgnored var run: (@Sendable (ProgramCommand, [UInt8]) async throws -> ProgramResult)?
    @ObservationIgnored var now: () -> Date = { Date() }
    /// The composer whose box it writes in, which is the newest one made for
    /// its worktree while an agent writes.
    @ObservationIgnored private(set) weak var composer: CommitComposer?
    /// The run under way, which isn't tied to any view.
    @ObservationIgnored private(set) var running: Task<Void, Never>?
    /// What the latest run asked the agent, for tests.
    @ObservationIgnored private(set) var lastRequest: CommitMessageRequest?
    /// What was in the box before the agent wrote, which Stop and Undo give
    /// back, and which a box that takes the agent over shows meanwhile.
    @ObservationIgnored private(set) var before = ""
    /// Whether the agent is rewriting the message of the commit `HEAD` is on,
    /// so that a box that takes it over turns Amend on.
    @ObservationIgnored private(set) var amends = false

    /// The agents writing in every worktree, which this one is among while
    /// it writes.
    @ObservationIgnored private let generators: MessageGenerators
    /// The composer it writes in, held while an agent writes, so that a
    /// message that arrives after its worktree has left Roga's memory still
    /// becomes its draft.
    @ObservationIgnored private var holding: CommitComposer?
    /// Counts runs, so that one that was stopped or replaced can't fill the box
    /// when it ends.
    @ObservationIgnored private var runs = 0

    init(generators: MessageGenerators) {
        self.generators = generators
    }

    /// Writes in `composer`'s box from now on, as when a box made for the
    /// worktree again takes over an agent that's writing.
    func attach(to composer: CommitComposer) {
        self.composer = composer
        if isWriting { holding = composer }
    }

    var isWriting: Bool {
        if case .writing = phase { true } else { false }
    }

    var readiness: Readiness {
        guard let composer, !isWriting, composer.phase != .committing, let loaded = composer.changes.loaded else { return .busy }
        if case .rebase = composer.stoppedWork { return .rebasing }
        // Right after Amend is ticked, the box still has the draft for a new
        // commit. Generating then would rewrite that draft as the amended
        // commit's message, and Undo would put it back under Amend.
        if composer.isReadingAmendedMessage { return .busy }
        if loaded.staged.isEmpty, !composer.isAmending { return .nothingStaged }
        return .ready
    }

    /// Asks the agent in `setup` for a message, starting from the box's text
    /// when it has any, and puts the agent's message in the box. With no setup,
    /// because no agent can be used, it does nothing.
    func generate(with setup: GenerationSetup?) {
        guard let setup, let composer, readiness == .ready else { return }
        runs += 1
        let run = runs
        let (session, worktree, changes) = (composer.session, composer.worktree, composer.changes)
        let message = composer.message
        let draft = message.allSatisfy(\.isWhitespace) ? nil : message
        let amending = composer.isAmending
        let branch = composer.currentBranch().map(Ref.shortName)
        let runner = self.run ?? { [programs = setup.programs] command, input in
            try await programs.run(command, input: input)
        }
        before = message
        amends = amending
        phase = .writing(Writing(kind: setup.kind, since: now()))
        holding = composer
        generators.started(self, in: worktree)
        running = Task { [session, worktree, changes] in
            do {
                // A press of Space may still be on its way to git.
                await changes.applyingIndexChanges?.value
                async let reading = session.stagedChanges(in: worktree, amending: amending)
                // The style is a nicety, so not getting the subjects doesn't stop it.
                async let subjects = setup.matchesStyle ? (try? await session.recentSubjects(in: worktree)) ?? [] : []
                // Right after Space, Stage All or Unstage All, the list is Roga's
                // own guess at what git will say, which has no blob IDs for the
                // files it moved. The staged files to compare with afterward are
                // the ones git lists next, which it reads while the agent's
                // input is read.
                await changes.loading?.value
                let stagedBefore = Self.stagedFiles(in: changes.loaded)
                let staged = try await reading
                let request = CommitMessageRequest(
                    worktree: worktree,
                    branch: branch,
                    changes: Self.input(from: staged),
                    recentSubjects: await subjects,
                    draft: draft,
                    style: setup.style
                )
                lastRequest = request
                try Task.checkCancellation()
                let written = try await CommitMessageWriter.write(request, with: setup.agent, run: runner)
                guard run == runs else { return }
                // The box may be one made for the worktree again since, whose
                // files are the ones Roga lists now.
                let box = holding ?? self.composer
                let stagedAfter = Self.stagedFiles(in: box?.changes.loaded)
                // The box changes while the phase still says writing, so that
                // the change isn't taken for an edit, which sends the note away.
                box?.message = written.text
                ended()
                phase = .written(Written(
                    label: setup.label,
                    duration: written.duration,
                    stagedFilesChanged: stagedBefore != nil && stagedAfter != nil && stagedBefore != stagedAfter,
                    subject: Self.subject(of: written.text)
                ))
            } catch {
                guard run == runs else { return }
                ended()
                fail(error, kind: setup.kind)
            }
        }
    }

    /// Stops the agent and gives the box back as it was.
    func stop() {
        guard isWriting else { return }
        runs += 1
        running?.cancel()
        let box = holding ?? composer
        ended()
        phase = .idle
        if let box, box.message != before { box.message = before }
    }

    /// Lets go of what a run holds once it's over, however it ended.
    private func ended() {
        running = nil
        holding = nil
        generators.ended(self)
    }

    /// Puts back what was in the box before the agent wrote.
    func undo() {
        guard case .written = phase else { return }
        phase = .idle
        composer?.message = before
    }

    /// Forgets what the latest run came to, as committing does.
    func forget() {
        guard !isWriting else { return }
        phase = .idle
    }

    /// Hears that the box's text changed. Changing the subject the agent wrote,
    /// which emptying the box does too, makes the message the author's, so the
    /// note and its Undo go. A failure goes at the first change.
    func messageChanged(to message: String) {
        switch phase {
        case .written(let written):
            if Self.subject(of: message) != written.subject { phase = .idle }
        case .failed:
            phase = .idle
        case .idle, .writing:
            break
        }
    }

    private func fail(_ error: any Error, kind: AgentKind) {
        if error is CancellationError {
            phase = .idle
        } else if let error = error as? CommitMessageError {
            // Output that only says what the sentence says isn't worth unfolding.
            let output = error.output.flatMap { $0 == error.description ? nil : $0 }
            phase = .failed(Failure(kind: kind, message: error.description, output: output))
        } else {
            // git couldn't say what's staged.
            phase = .failed(Failure(kind: kind, message: error.dialogMessage, output: nil))
        }
    }

    /// Puts it in a phase, for tests of what the box shows.
    func setPhaseForTests(_ phase: Phase) {
        self.phase = phase
    }

    // MARK: What it says

    /// The line under the box while an agent writes, which counts the seconds
    /// from the first one on: "Claude Code is writing… 3 s".
    static func writingWords(_ kind: AgentKind, since: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(since))
        return seconds >= 1 ? "\(kind.name) is writing… \(seconds) s" : "\(kind.name) is writing…"
    }

    /// The note under the box once an agent has written: "Claude Code · haiku
    /// wrote this in 4 s.", and a second sentence when the staged files changed
    /// meanwhile.
    static func writtenWords(_ written: Written) -> String {
        let (seconds, attoseconds) = written.duration.components
        let rounded = max(1, Int((Double(seconds) + Double(attoseconds) / 1e18).rounded()))
        let words = "\(written.label) wrote this in \(rounded) s."
        return written.stagedFilesChanged ? words + " The staged files changed while it wrote." : words
    }

    /// The heading of the card that says an agent failed.
    static func failureTitle(_ kind: AgentKind) -> String {
        "\(kind.name) didn't write a message"
    }

    // MARK: Helpers

    static func subject(of message: String) -> String {
        String(message.prefix { !$0.isNewline })
    }

    /// What's staged, as far as telling whether it changed goes. Line counts
    /// are left out, because they're filled in after the files are listed.
    private struct StagedFile: Equatable {
        var path: String
        var oldPath: String?
        var status: DiffFile.Status
        var newID: ObjectID?
        var newMode: UInt32
    }

    private static func stagedFiles(in changes: WorktreeChanges?) -> [StagedFile]? {
        changes?.staged.map { StagedFile(path: $0.path, oldPath: $0.oldPath, status: $0.status, newID: $0.newID, newMode: $0.newMode) }
    }

    /// The staged changes as the agent reads them. AgentEngine has its own copy
    /// of the type, since it can't import RepositoryEngine.
    private static func input(from staged: StagedChanges) -> CommitMessageInput {
        CommitMessageInput(
            files: staged.files.map {
                CommitMessageInput.File(path: $0.path, oldPath: $0.oldPath, status: $0.status, added: $0.added, deleted: $0.deleted, note: $0.note)
            },
            patch: staged.patch,
            isCut: staged.isCut
        )
    }
}

/// The agents writing commit messages, by the worktree each writes for
/// (decision 41).
///
/// A worktree's commit box is made again when the window that showed it is
/// closed and another opens it, or once a window has shown eight other
/// worktrees, and its agent may still be writing then. The new box takes the
/// agent over: it waits with the bars, offers Stop and gets the message,
/// rather than offer Generate again and lose the message to its next keystroke.
///
/// Roga stops them all when it quits. Each agent runs in a process group of
/// its own, with a time limit that only Roga keeps, so it would otherwise go
/// on running, and spend a request on a message nobody sees.
final class MessageGenerators {
    /// The ones Roga's windows share.
    static let shared: MessageGenerators = {
        let generators = MessageGenerators()
        generators.stopWhenRogaQuits()
        return generators
    }()

    private var writing: [String: MessageGenerator] = [:]
    private var termination: (any NSObjectProtocol)?

    /// The generator whose agent is writing for the worktree in `folder`.
    func writing(in folder: String) -> MessageGenerator? {
        writing[folder]
    }

    func started(_ generator: MessageGenerator, in folder: String) {
        writing[folder] = generator
    }

    func ended(_ generator: MessageGenerator) {
        writing = writing.filter { $0.value !== generator }
    }

    /// Stops every agent that's writing, and gives each box back what it had.
    func stopAll() {
        for generator in Array(writing.values) {
            generator.stop()
        }
    }

    private func stopWhenRogaQuits() {
        termination = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopAll()
            }
        }
    }
}
