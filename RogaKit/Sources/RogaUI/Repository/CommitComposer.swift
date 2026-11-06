import Foundation
import GitCore
import GitRunner
import Observation
import RepositoryEngine

/// Where the message of a worktree's next commit is kept while someone is writing
/// it, so that switching between agents or quitting Roga doesn't lose it. It's
/// what someone typed rather than anything about the repository, so it lives with
/// Roga's own settings and not in the repository.
struct CommitDrafts {
    var read: (_ worktree: String) -> String
    var write: (_ worktree: String, _ message: String) -> Void

    static let standard = CommitDrafts { worktree in
        UserDefaults.standard.string(forKey: key(worktree)) ?? ""
    } write: { worktree, message in
        if message.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(worktree))
        } else {
            UserDefaults.standard.set(message, forKey: key(worktree))
        }
    }

    /// Keeps nothing, for tests.
    static let none = CommitDrafts { _ in "" } write: { _, _ in }

    private static func key(_ worktree: String) -> String {
        "commitDraft " + worktree
    }
}

/// The message of a worktree's next commit, and making that commit (decision 30).
@Observable
final class CommitComposer {
    enum Phase: Equatable {
        case idle
        /// git is committing, which takes as long as the user's hooks and signing do.
        case committing
        /// git or a hook refused, and this is what it printed.
        case failed(String)
    }

    /// The button at the bottom of the box.
    struct Action: Equatable {
        var title: String
        var isEnabled: Bool
    }

    /// The message, which is what the box edits.
    var message = "" {
        didSet {
            guard message != oldValue else { return }
            saveDraft()
            generator.messageChanged(to: message)
        }
    }
    /// Whether the next commit replaces the one `HEAD` is on.
    private(set) var isAmending = false
    /// Whether Amend is still reading the message of the commit `HEAD` is on.
    /// Until that message is in the box, the box holds the draft for a new
    /// commit, so Generate waits rather than rewrite the wrong message.
    private(set) var isReadingAmendedMessage = false
    private(set) var phase = Phase.idle
    /// Whether committing has taken long enough to say what it's waiting for.
    private(set) var isSlow = false
    /// The latest commit made here, which can be taken back.
    private(set) var lastCommit: MadeCommit?
    /// Goes up when something asks for the keyboard to go to the box.
    private(set) var focusRequests = 0
    /// What the worktree is partway through, if anything.
    private(set) var stoppedWork: StoppedWork?
    /// The message of the commit a rebase stopped on, which the box shows as it is
    /// and can't change yet.
    private(set) var rebaseMessage = ""
    /// Has an agent write the message, for the box's Generate button and the
    /// Changes menu (decision 41). It's another one once a box made for the
    /// worktree again has taken over the agent that was writing here.
    private(set) var generator: MessageGenerator

    /// The current branch's full name, or nil for a detached `HEAD`.
    @ObservationIgnored var currentBranch: () -> String? = { nil }
    /// Selects a commit that was just made, when nothing's left to commit.
    @ObservationIgnored var select: (ObjectID) -> Void = { _ in }
    /// Selects the row for uncommitted changes, as soon as it's there.
    @ObservationIgnored var showChanges: () -> Void = {}
    /// How long committing runs before the box says what it's waiting for.
    @ObservationIgnored var slowDelay = Duration.milliseconds(600)

    /// The repository, which the generator reads the staged changes from.
    @ObservationIgnored let session: RepositorySession
    /// The worktree's folder, which the command that writes its message runs in.
    @ObservationIgnored let worktree: String
    @ObservationIgnored private let branch: BranchModel
    /// The worktree's files, which the generator tells whether anything's
    /// staged from.
    @ObservationIgnored let changes: SelectedChanges
    @ObservationIgnored private let drafts: CommitDrafts
    /// The agents writing in every worktree, one of which this box takes
    /// over when it's made while an agent writes for its worktree.
    @ObservationIgnored private let generators: MessageGenerators
    /// What was in the box before Amend replaced it with the commit's own message.
    @ObservationIgnored private var draftBeforeAmending: String?
    /// The message git had ready for a merge, while it hasn't been changed.
    @ObservationIgnored private var mergeMessage: String?
    /// The message of the latest commit made here, for putting back.
    @ObservationIgnored private var lastMessage = ""
    @ObservationIgnored private(set) var readingMessage: Task<Void, Never>?
    /// Counts Amend's reads of `HEAD`'s message, so that one Amend has since
    /// left behind doesn't say the latest one is done.
    @ObservationIgnored private var amendReads = 0
    @ObservationIgnored private var slowNote: Task<Void, Never>?

    init(
        session: RepositorySession,
        worktree: String,
        branch: BranchModel,
        changes: SelectedChanges,
        drafts: CommitDrafts,
        generators: MessageGenerators = .shared
    ) {
        self.session = session
        self.worktree = worktree
        self.branch = branch
        self.changes = changes
        self.drafts = drafts
        self.generators = generators
        let writing = generators.writing(in: worktree)
        generator = writing ?? MessageGenerator(generators: generators)
        message = drafts.read(worktree)
        if let writing {
            takeOver(writing)
        } else {
            generator.attach(to: self)
        }
    }

    /// Takes over an agent that's writing for this worktree in a box that
    /// was made before, whose window has closed or forgotten it, so that the
    /// message comes here. This box shows what that one did meanwhile: the
    /// text from before the agent started, under the bars, and Amend when
    /// the agent is rewriting the message of the commit `HEAD` is on. The
    /// draft for a new commit is then the one Amend saved.
    private func takeOver(_ writing: MessageGenerator) {
        let previous = writing.composer
        writing.attach(to: self)
        if writing.amends {
            draftBeforeAmending = message
            isAmending = true
        }
        message = writing.before
        previous?.letGo(of: writing)
    }

    /// Lets the agent that's writing here go to a newer box for the worktree,
    /// and starts again with a generator of its own.
    private func letGo(of writing: MessageGenerator) {
        guard generator === writing else { return }
        generator = MessageGenerator(generators: generators)
        generator.attach(to: self)
    }

    private var isMerging: Bool { stoppedWork == .merge }
    private var isRebasing: Bool {
        if case .rebase = stoppedWork { true } else { false }
    }

    /// Whether the box has more than blank lines and spaces in it.
    var hasMessage: Bool {
        !message.allSatisfy(\.isWhitespace)
    }

    /// Whether there's a commit to amend, and nothing partway through in the way.
    var canAmend: Bool {
        stoppedWork == nil && changes.loaded?.head != nil
    }

    /// Whether the box shows text that can't be changed, because it isn't the
    /// message of a commit that's being made.
    var isMessageReadOnly: Bool {
        isRebasing || phase == .committing || generator.isWriting
    }

    /// The text the box shows.
    var shownMessage: String {
        isRebasing ? rebaseMessage : message
    }

    /// How long the first line is, which turns red past `subjectLimit`.
    var subjectLength: Int {
        shownMessage.prefix { !$0.isNewline }.count
    }

    /// As long as a subject should be, by git's own habit.
    static let subjectLimit = 72

    /// What the heading above the box says, as a lead-in and what it's about.
    var heading: (lead: String, subject: String) {
        if isAmending, let head = changes.loaded?.head { return ("Amend", String(head.hex.prefix(8))) }
        switch stoppedWork {
        case .merge:
            return ("Commit merge", "")
        case .rebase(let name):
            return ("Rebasing", name.map(Ref.shortName) ?? "")
        case nil:
            break
        }
        guard let name = currentBranch() else { return ("Commit on detached", "HEAD") }
        return (changes.loaded?.head == nil ? "First commit on" : "Commit to", Ref.shortName(name))
    }

    /// A sentence about something worth knowing before committing.
    var note: String? {
        if isAmending, let status = branch.status, let upstream = status.upstream, status.ahead == 0, let head = changes.loaded?.head {
            return "\(head.hex.prefix(8)) is on \(Ref.shortName(upstream)), so pushing this afterward will need a force push."
        }
        if stoppedWork == nil, currentBranch() == nil, changes.loaded != nil {
            return "No branch will point to this commit until you start one from it."
        }
        return nil
    }

    /// What the button says and whether it can be pressed.
    var action: Action {
        if phase == .committing { return Action(title: "Committing…", isEnabled: false) }
        // Nothing commits while git is busy, while an agent is still writing
        // the message, or while Amend hasn't put the commit's message in the
        // box, which until then has the draft for a new commit.
        guard !branch.isBusy, !generator.isWriting, !isReadingAmendedMessage else {
            return Action(title: buttonTitle, isEnabled: false)
        }
        let conflicts = changes.loaded?.conflicted.count ?? 0
        if conflicts > 0 {
            return Action(title: conflicts == 1 ? "1 Conflict Left" : "\(conflicts.formatted()) Conflicts Left", isEnabled: false)
        }
        if isRebasing { return Action(title: "Continue Rebase", isEnabled: true) }
        let hasFiles = (changes.loaded?.fileCount ?? 0) > 0
        return Action(title: buttonTitle, isEnabled: hasMessage && (hasFiles || isAmending))
    }

    private var buttonTitle: String {
        if case .failed = phase { return "Try Again" }
        if isRebasing { return "Continue Rebase" }
        if isAmending { return "Amend Commit" }
        if isMerging { return "Commit Merge" }
        let staged = changes.loaded?.staged.count ?? 0
        if staged == 0 { return "Stage All and Commit" }
        return staged == 1 ? "Commit 1 File" : "Commit \(staged.formatted()) Files"
    }

    /// Whether a failure could have been a hook's, so that skipping hooks could help.
    /// git says the same few words when signing fails, which hooks have nothing to do with.
    var canSkipHooks: Bool {
        guard case .failed(let output) = phase else { return false }
        return !output.contains("failed to sign") && !output.contains("failed to write commit object")
    }

    func askForFocus() {
        focusRequests += 1
    }

    /// Fills the box with the message of the commit `HEAD` is on, or puts back what
    /// was there before.
    func setAmending(_ isOn: Bool) {
        guard isOn != isAmending, phase != .committing, !generator.isWriting else { return }
        if case .failed = phase { phase = .idle }
        guard isOn else {
            isAmending = false
            isReadingAmendedMessage = false
            message = draftBeforeAmending ?? ""
            draftBeforeAmending = nil
            return
        }
        guard let head = changes.loaded?.head else { return }
        draftBeforeAmending = message
        isAmending = true
        isReadingAmendedMessage = true
        amendReads += 1
        let read = amendReads
        readingMessage = Task {
            let commit = try? await session.commits([head]).first ?? nil
            guard read == amendReads else { return }
            defer { isReadingAmendedMessage = false }
            guard let commit, isAmending else { return }
            message = commit.message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Hears what the worktree is partway through whenever someone looks, and shows
    /// the message git has ready for it.
    func worktreeIsPartway(through work: StoppedWork?) {
        guard work != stoppedWork else { return }
        stoppedWork = work
        if work != nil {
            // An agent was writing for a commit that isn't the one being made
            // now, so it stops before Amend goes off, which it would otherwise
            // refuse while the agent writes.
            generator.stop()
            setAmending(false)
        }
        // A merge that was aborted takes its message along, unless someone changed it.
        if work == nil, let mergeMessage, message == mergeMessage { message = "" }
        mergeMessage = nil
        rebaseMessage = ""
        guard let work else { return }
        readingMessage = Task {
            let text = try? await session.message(for: work, in: worktree)
            guard work == stoppedWork, let text else { return }
            if case .merge = work {
                if hasMessage { return }
                mergeMessage = text
                message = text
            } else {
                rebaseMessage = text
            }
        }
    }

    /// Does what the button says. With nothing staged, that's staging everything
    /// first, all of which is listed right above the box. Your hooks and signing run.
    ///
    /// - Parameter skippingHooks: Whether to leave out the user's hooks, which is
    ///   only offered once one has failed.
    func commit(skippingHooks: Bool = false) {
        guard action.isEnabled else { return }
        if isRebasing {
            branch.run(.continuingRebase, failure: "Can't continue the rebase") { [session, worktree] in
                try await session.continueRebase(in: worktree)
                return "Continued"
            }
            return
        }
        let request = CommitRequest(message: message, amends: isAmending, skipsHooks: skippingHooks)
        // An agent's note is about the message, which is now on its way into a commit.
        generator.forget()
        let stagesFirst = !isAmending && !isMerging && changes.loaded?.staged.isEmpty == true
        let wasAmending = isAmending
        phase = .committing
        isSlow = false
        slowNote = Task {
            guard (try? await Task.sleep(for: slowDelay)) != nil else { return }
            isSlow = true
        }
        branch.run(.committing, failure: "Can't commit") { [self, session, worktree] in
            defer {
                slowNote?.cancel()
                isSlow = false
            }
            do {
                // A press of Space may still be on its way to git.
                await changes.applyingIndexChanges?.value
                if stagesFirst { try await session.stageEverything(in: worktree) }
                let made = try await session.commit(request, in: worktree)
                finish(made, message: request.message)
                if (try? await session.status(in: worktree).fileCount) == 0 { select(made.id) }
                return "\(wasAmending ? "Amended" : "Committed") \(made.id.hex.prefix(8))"
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.dialogMessage)
            }
            return nil
        }
    }

    /// Commits, then pushes the way `↑` does.
    func commitAndPush() {
        commit()
        guard phase == .committing, let running = branch.running else { return }
        Task {
            await running.value
            guard phase == .idle, lastCommit != nil else { return }
            await branch.refresh()
            branch.push()
        }
    }

    /// Stops a commit that's taking too long, as when a hook has hung.
    func stop() {
        branch.running?.cancel()
    }

    private func finish(_ made: MadeCommit, message: String) {
        lastMessage = message
        lastCommit = made.previous == nil ? nil : made
        isAmending = false
        draftBeforeAmending = nil
        phase = .idle
        self.message = ""
        branch.undoFinished = made.previous == nil ? nil : .init(help: "Undo the Commit") { [weak self] in self?.undoLastCommit() }
    }

    /// Takes back the latest commit made here, leaving its files staged, and puts
    /// its message back in the box. It won't if anything has moved `HEAD` since.
    ///
    /// An agent that's writing stops, since it's describing what was staged
    /// before the commit's files came back, and its message would take the
    /// place of the one this puts back.
    func undoLastCommit() {
        guard let commit = lastCommit, !branch.isBusy else { return }
        let restored = lastMessage
        branch.run(nil, failure: "Can't undo the commit", changesNothing: true) { [self, session, worktree] in
            try await session.undo(commit, in: worktree)
            lastCommit = nil
            generator.stop()
            // A note's Undo would put back what was there before the agent
            // wrote, rather than the message this brings back.
            generator.forget()
            message = restored
            showChanges()
            return "Undid the commit"
        }
    }

    private func saveDraft() {
        if isAmending {
            drafts.write(worktree, draftBeforeAmending ?? "")
        } else if message == mergeMessage {
            drafts.write(worktree, "")
        } else {
            drafts.write(worktree, message)
        }
    }
}
