import Foundation
import GitCore
import GitRunner
import Observation
import RepositoryEngine

/// A worktree's branch in the title row: where it stands against its upstream,
/// and fetching, pulling, pushing and starting a new branch (decisions 19 and
/// 20). All of this acts on the branch the worktree has checked out, whatever is
/// selected in history. Deleting a branch is here because it can't run alongside
/// those, and it acts on whichever branch's menu someone opened.
@Observable
final class BranchModel {
    /// What git is doing because someone asked it to. Nothing else runs until
    /// it finishes.
    enum Action: Equatable {
        case pulling
        case pushing
        case forcePushing
        case fetching
        case undoing
        case aborting
        case deletingFromRemote
        case committing
        case continuingRebase
        case reverting
        case merging
        case fastForwarding
        case rebasing
        case cherryPicking

        var title: String {
            switch self {
            case .pulling: "Pulling…"
            case .pushing: "Pushing…"
            case .forcePushing: "Force pushing…"
            case .fetching: "Fetching…"
            case .undoing: "Undoing…"
            case .aborting: "Aborting…"
            case .deletingFromRemote: "Deleting…"
            case .committing: "Committing…"
            case .continuingRebase: "Continuing…"
            case .reverting: "Reverting…"
            case .merging: "Merging…"
            case .fastForwarding: "Fast-forwarding…"
            case .rebasing: "Rebasing…"
            case .cherryPicking: "Cherry-picking…"
            }
        }
    }

    /// Which way the commits go, for a count in the title row.
    enum Direction: Equatable {
        case pull
        case push
    }

    /// Something git refused, and what it said about that.
    struct Failure: Equatable {
        var title: String
        var message: String
        /// What ran, by its arguments after `git`, which shows above what git said.
        /// Without it, the message goes with the dialog's words.
        var command: [String]? = nil
        /// Whether the dialog can say that nothing changed.
        var changedNothing = false
        /// What the dialog says about how far it got, in place of that.
        var summary: DialogText? = nil

        /// Says what went wrong with something git was asked to run.
        init(title: String, error: any Error, changedNothing: Bool = false) {
            if let refused = error as? RefusedWithChangesAside {
                self.init(title: title, message: refused.refusal.dialogMessage, command: refused.refusal.gitArguments)
                summary = .sentences([
                    "Nothing moved, but Roga couldn't put your uncommitted changes back, so they're still in the stash \(code: refused.aside.message).",
                    "What git said is below.",
                ])
                return
            }
            self.init(title: title, message: error.dialogMessage, command: error.gitArguments, changedNothing: changedNothing)
        }

        init(title: String, message: String, command: [String]? = nil, changedNothing: Bool = false) {
            self.title = title
            self.message = message
            self.command = command
            self.changedNothing = changedNothing
        }
    }

    /// A pull, a merge, a rebase, a revert or a cherry-pick that hit a conflict, which
    /// Roga can't resolve, so it asks whether to undo it or leave it for the command line.
    struct Conflict: Equatable {
        /// The merge or rebase a pull stopped partway through, or the revert.
        var work: StoppedWork
        /// The files in conflict. git prints these to its standard output, which
        /// a failure doesn't keep, so they come from asking it again.
        var files: [String]
        /// What ran and stopped, by its arguments after `git`.
        var ran: [String]? = nil
        /// How many files were staged before a revert that was to leave its changes
        /// uncommitted. Undoing it takes those back to `HEAD` too.
        var stagedBefore = 0
        /// The uncommitted changes that were set aside for the pull, which undoing
        /// it puts back (decision 59).
        var aside: ChangesAside? = nil
        /// Whether someone asked for this merge or rebase by name, rather than a pull
        /// turning into one.
        var isOwnWork = false

        /// Whether a pull stopped, rather than something asked for by name.
        var startedByPull: Bool {
            switch work {
            case .revert, .cherryPick: false
            case .merge, .rebase: !isOwnWork
            }
        }
    }

    /// Uncommitted changes that were set aside for a pull or for going to a commit,
    /// and came back with conflicts, until the user has said what to do (decision 59).
    struct PutBackConflict: Equatable {
        var aside: ChangesAside
        /// The files in conflict.
        var files: [String]
        /// What ran, each by its arguments after `git`: setting the changes aside,
        /// the move, and putting them back.
        var ran: [[String]]

        /// What the move is called in a sentence, as in `the pull`.
        var noun: String {
            switch aside.move {
            case .pull: "pull"
            case .reset: "reset"
            case .detach: "switch"
            case .merge: "merge"
            case .rebase: "rebase"
            case .cherryPick: "cherry-pick"
            }
        }
    }

    /// git refused a move, and the uncommitted changes that were set aside for it
    /// couldn't go back either, which the dialog has to say.
    struct RefusedWithChangesAside: Error {
        var refusal: any Error
        var aside: ChangesAside
    }

    /// A force push that's waiting for someone to agree to what it overwrites.
    struct ForcePush: Equatable {
        var branch: String
        var upstream: String
        /// How many commits it overwrites, and the first few.
        var count: Int
        var commits: [ListedCommit]
    }

    /// A merge or a rebase that's waiting for someone to agree to it.
    struct PendingIntegration: Equatable {
        var integration: BranchIntegration
        /// The newest commits it's about.
        var commits: [ListedCommit]
    }

    /// Where a new branch or tag starts, when that isn't where the worktree is.
    struct NewRefStart: Equatable {
        var commit: ObjectID
        /// What to call it, such as a branch's name or a short hash.
        var label: String
    }

    /// A deletion that's waiting for someone to agree to it.
    struct PendingDeletion: Equatable {
        var deletion: BranchDeletion
        /// The newest commits it loses.
        var commits: [ListedCommit]
        /// The short names of the branches beside it that are staying because they're
        /// checked out, which the dialog mentions.
        var checkedOut: [String] = []
    }

    /// Deleting some of the branches on a commit, while someone chooses which.
    struct BranchChoice: Equatable {
        var deletion: CommitBranchesDeletion
        /// The full names of what's picked so far. This lives with the question rather
        /// than in the view, so that a button reads it when it's pressed.
        var picked: Set<String>
        /// The newest commits that deleting all of them loses.
        var commits: [ListedCommit]

        /// Starts with every local branch going and every remote branch staying, unless
        /// those local branches are all there is and would take commits with them. There's
        /// no telling then which name to keep, so nothing starts on.
        init(deletion: CommitBranchesDeletion, commits: [ListedCommit]) {
            self.deletion = deletion
            self.commits = commits
            let local = deletion.branches.filter { $0.place == .local }
            let losesCommits = deletion.lostCount > 0 && local.count == deletion.branches.count
            picked = losesCommits ? [] : Set(local.map(\.ref))
        }

        /// What's picked, with remotes last, because they're shared.
        var deletions: [BranchDeletion] {
            let picked = deletion.branches.filter { self.picked.contains($0.ref) }
            return picked.filter { !$0.reachesRemote } + picked.filter(\.reachesRemote)
        }

        /// How many commits go with what's picked. Any branch that stays keeps them all,
        /// because they're all on one commit.
        var lostCount: Int {
            picked.count == deletion.branches.count ? deletion.lostCount : 0
        }

        /// Whether what's picked can't be brought back, or reaches a remote.
        var isDestructive: Bool {
            lostCount > 0 || deletions.contains(where: \.reachesRemote)
        }

        /// Picks a branch that isn't picked, and the other way around.
        mutating func flip(_ ref: String) {
            if picked.remove(ref) == nil { picked.insert(ref) }
        }
    }

    /// The most commits to list before a force push or a deletion.
    private static let overwrittenLimit = DialogContent.listLimit
    /// The most commits to tint in history while the pointer is over a count.
    private static let previewLimit = 1000
    /// How long what happened stays in the title row.
    private static let finishedDuration = Duration.seconds(3)
    /// How long it stays when it comes with a button for undoing it, which takes
    /// a moment to get to.
    private static let undoableDuration = Duration.seconds(8)

    let session: RepositorySession
    /// The worktree's folder.
    let worktree: String
    /// Where the branch stands, or nil when the worktree isn't on a branch, or
    /// its branch has no commits yet.
    private(set) var status: BranchStatus?
    /// What became of the repository's latest fetch.
    private(set) var fetchRecord = FetchRecord()
    /// Whether Roga is fetching by itself, which the branch's menu says and the
    /// Fetch button shows by dropping the house through it.
    private(set) var isFetchingByItself = false
    /// What git is doing because someone asked it to.
    private(set) var action: Action?

    /// Whether any fetch is running, whoever asked for it, which the Fetch button
    /// shows by dropping the house through it (decisions 45 and 57).
    var isFetching: Bool { action == .fetching || isFetchingByItself }

    /// What just happened, as in `Pulled`, for a moment.
    private(set) var finished: String?
    /// What takes back what just happened, as for a commit. It's set before `work`
    /// returns, and it goes along with the words.
    var undoFinished: FinishedUndo?
    /// What to tell the user about something that didn't work, until they've
    /// seen it.
    var failure: Failure?
    /// A pull or a revert that stopped on a conflict, until the user has said what
    /// to do.
    var conflict: Conflict?
    /// Changes set aside for a move that came back with conflicts, until the user
    /// has said what to do.
    var putBackConflict: PutBackConflict?
    /// A pull that needs someone to choose between rebasing and merging.
    var pullChoice: PullChoice?
    /// What the worktree is stuck partway through, whoever started it, which
    /// takes the place of the counts. The worktree's model keeps this current.
    var unfinished: UnfinishedWork?
    /// A merge, a rebase or a revert that's waiting for someone to agree to abort it.
    var pendingAbort: StoppedWork?
    /// A force push that's waiting for someone to agree to it.
    var forcePush: ForcePush?
    /// A merge or a rebase that's waiting for someone to agree to it.
    var pendingIntegration: PendingIntegration?
    /// A deletion that's waiting for someone to agree to it.
    var pendingDeletion: PendingDeletion?
    /// A deletion that's waiting for someone to choose what goes.
    var branchChoice: BranchChoice?
    /// Whether the popover for a new branch shows.
    var isCreatingBranch = false
    /// Whether that popover starts with In a new worktree checked, as it does
    /// from the menu of the repository's worktrees.
    var startsInNewWorktree = false
    /// The commit that popover starts the branch from, when someone chose one.
    var newBranchStart: NewRefStart?
    /// The commit that the popover for a new tag puts it on, while that shows.
    var newTagStart: NewRefStart?

    /// Shows the popover for a new branch, ready to make it in a new worktree.
    func startNewWorktree() {
        guard !isBusy else { return }
        startsInNewWorktree = true
        isCreatingBranch = true
    }

    /// Shows the popover for a new branch, starting from a commit.
    func startNewBranch(at commit: ObjectID, named label: String, inNewWorktree: Bool = false) {
        guard !isBusy else { return }
        newBranchStart = NewRefStart(commit: commit, label: label)
        startsInNewWorktree = inNewWorktree
        isCreatingBranch = true
    }

    /// Shows the popover for a new tag on a commit.
    func startNewTag(at commit: ObjectID, named label: String) {
        guard !isBusy else { return }
        newTagStart = NewRefStart(commit: commit, label: label)
    }

    /// Whether the user wants Roga to fetch by itself.
    @ObservationIgnored private let fetchesByItself: () -> Bool
    /// Says that the worktree or its branches changed, because of something Roga
    /// did, and returns once the sidebar knows.
    @ObservationIgnored private let reportBranchChange: () async -> Void
    /// Whether a checkout is running, which nothing here may run alongside.
    @ObservationIgnored var isCheckingOut: () -> Bool = { false }
    /// Asks the worktree's model to look at what a fetch or a pull may have moved.
    @ObservationIgnored var lookAgain: () -> Void = {}
    /// Asks the worktree's model to select the row for uncommitted changes and
    /// its first conflicted file, for resolving it (decision 60).
    @ObservationIgnored var showConflicts: () -> Void = {}
    /// How many files are staged in the worktree, which aborting a revert takes back.
    @ObservationIgnored var stagedFiles: () -> Int = { 0 }
    /// Asks history to tint these commits, or none.
    @ObservationIgnored var showPreview: ([ObjectID]) -> Void = { _ in }
    /// How long the house takes to play once for an action, which is how long
    /// the action stays in the title row when git finishes sooner.
    @ObservationIgnored var timeToPlayHouse: (Action) -> Duration = { $0.timeToPlayHouse }
    /// How long what happened stays in the title row, given whether it can be
    /// undone. Tests stretch it, so that a slow run doesn't see it go before
    /// they look.
    @ObservationIgnored var timeToShowFinished: (_ canUndo: Bool) -> Duration = { $0 ? BranchModel.undoableDuration : BranchModel.finishedDuration }
    @ObservationIgnored private(set) var running: Task<Void, Never>?
    /// Finding out what deleting a branch would come to.
    @ObservationIgnored private(set) var preparingDeletion: Task<Void, Never>?
    /// Finding out what a merge or a rebase would come to.
    @ObservationIgnored private(set) var preparingIntegration: Task<Void, Never>?
    @ObservationIgnored private(set) var quietFetch: Task<Void, Never>?
    @ObservationIgnored private(set) var previewing: Task<Void, Never>?
    @ObservationIgnored private var finishedNote: Task<Void, Never>?

    init(
        session: RepositorySession,
        worktree: String,
        fetchesByItself: @escaping () -> Bool = { UserDefaults.standard.fetchesByItself },
        reportBranchChange: @escaping () async -> Void = {}
    ) {
        self.session = session
        self.worktree = worktree
        self.fetchesByItself = fetchesByItself
        self.reportBranchChange = reportBranchChange
    }

    /// Reads where the branch stands. When git can't say, it keeps what it knew.
    func refresh() async {
        guard let status = try? await session.branchStatus(in: worktree) as BranchStatus??, !Task.isCancelled else { return }
        self.status = status
        if fetchRecord == FetchRecord() { fetchRecord = await session.lastFetch() }
    }

    /// The branch's short name.
    private var branchName: String { status.map { Ref.shortName($0.branch) } ?? "" }

    /// The upstream's short name, or nil when there's none.
    private var upstreamName: String? { status?.upstream.map(Ref.shortName) }

    /// Whether anything that someone asks for has to wait.
    var isBusy: Bool { action != nil || running != nil || isCheckingOut() }

    // MARK: Fetching

    /// Fetches because Roga became active or a window started showing the
    /// repository, unless the user turned that off (decision 20). Nothing shows
    /// while it runs or if it fails, except in the branch's menu. The session
    /// decides whether it's been long enough since the last one.
    func fetchByItself() {
        guard fetchesByItself(), action == nil, quietFetch == nil, let remote = status?.remote else { return }
        isFetchingByItself = true
        quietFetch = Task {
            let before = fetchRecord
            let record = await session.fetchQuietly(from: remote)
            fetchRecord = record
            isFetchingByItself = false
            quietFetch = nil
            if record != before { lookAgain() }
        }
    }

    /// Fetches because someone asked to. Nothing opens in the title row, because
    /// the house drops through the Fetch button while it runs, and when it's done
    /// a count appears or ticks up (decisions 45 and 57). A fetch Roga started by
    /// itself stops, so that this one can report what goes wrong.
    func fetch() {
        guard let remote = status?.remote else { return }
        run(.fetching, failure: "Can't fetch from \(remote)") { [session, worktree] in
            try await session.fetch(from: remote, in: worktree)
            return nil
        }
    }

    // MARK: Pulling

    /// Pulls the way clicking `↓` does. When the branch has diverged and the user's
    /// configuration doesn't say how, it asks.
    func pull() {
        guard let status else { return }
        if let pull = status.pull {
            self.pull(pull)
        } else if status.hasDiverged {
            askHowToPull()
        }
    }

    /// Asks whether to rebase or merge.
    private func askHowToPull() {
        guard !isBusy, let status, let upstream = upstreamName else { return }
        // The count under the pointer won't say the pointer has left.
        preview(nil)
        pullChoice = PullChoice(branch: branchName, upstream: upstream, behind: status.behind, ahead: status.ahead)
    }

    /// Runs the pull that someone chose, and makes it the way this repository
    /// pulls from now on if they asked for that.
    func confirmPull() {
        guard let pullChoice else { return }
        self.pullChoice = nil
        pull(pullChoice.pick, remembering: pullChoice.remembers)
    }

    func pull(_ pull: Pull, remembering: Bool = false) {
        let move = status?.upstream.map { ChangesAside.Move.pull(upstream: $0, rebases: rebases(pull)) }
        let message = "Roga: before pulling \(branchName)"
        runMove(
            .pulling,
            failure: "Can't pull \(branchName)",
            move: move,
            message: message,
            arguments: pull.arguments,
            done: "Pulled",
            before: { [session, worktree] in if remembering { try await session.remember(pull, in: worktree) } },
            work: { [session, worktree] in try await session.pull(pull, in: worktree) }
        )
    }

    /// Runs something that moves `HEAD` and can stop on a conflict. Uncommitted changes
    /// that git would refuse to overwrite go aside and come back afterward (decision 59).
    ///
    /// - Parameters:
    ///   - move: What it means for uncommitted changes, or nil to leave them to git.
    ///   - message: The stash's message, if they go aside.
    ///   - arguments: What it runs, for the dialog when they come back with conflicts.
    ///   - done: What the title row says afterward.
    ///   - isOwnWork: Whether someone asked for this by name, rather than a pull.
    ///   - before: What has to happen first, and can stop it.
    private func runMove(
        _ action: Action,
        failure title: String,
        move: ChangesAside.Move?,
        message: String,
        arguments: [String],
        done: String,
        isOwnWork: Bool = false,
        before: @escaping () async throws -> Void = {},
        work: @escaping () async throws -> Void
    ) {
        run(action, failure: title, changesNothing: true) { [session, worktree] in
            try await before()
            let wasStopped = (try? await session.stoppedWork(in: worktree)) != nil
            var aside: ChangesAside?
            if let move, !wasStopped {
                aside = try await session.setAsideChanges(inTheWayOf: move, message: message, in: worktree)
            }
            do {
                try await work()
            } catch {
                // git hit a conflict just now, so this is its own mess to clean up,
                // rather than one that was there already.
                if !wasStopped, let stopped = try? await session.stoppedWork(in: worktree) {
                    let status = try? await session.status(in: worktree)
                    self.conflict = Conflict(work: stopped, files: status?.conflicted.map(\.path) ?? [], ran: error.gitArguments, aside: aside, isOwnWork: isOwnWork)
                    return nil
                }
                try await self.putBack(afterRefusing: error, aside)
                throw error
            }
            guard let aside else { return done }
            return try await self.putBack(aside, ran: [ChangesAside.arguments(message: message), arguments], done: done)
        }
    }

    // MARK: Merging and rebasing

    /// Finds out what bringing in a branch would come to. A fast-forward goes
    /// straight away, because it can't lose or rewrite anything, and a merge or a
    /// rebase asks, which is where it says what comes in.
    ///
    /// - Parameter ref: The other branch's full name.
    func askToIntegrate(_ way: BranchIntegration.Way, ref: String) {
        guard !isBusy, preparingIntegration == nil else { return }
        let name = Self.shortened(Ref.shortName(ref))
        preparingIntegration = Task {
            do {
                let integration = try await session.prepareToIntegrate(way, ref: ref, limit: Self.overwrittenLimit, in: worktree)
                if integration.incomingCount == 0 {
                    let here = integration.branch.map(Ref.shortName) ?? "HEAD"
                    failure = Failure(title: "Nothing to bring in", message: "\(here) already has everything on \(name).", changedNothing: true)
                } else if way == .fastForward {
                    integrate(integration)
                } else {
                    pendingIntegration = PendingIntegration(integration: integration, commits: await listed(integration.listed))
                }
            } catch {
                failure = Failure(title: "Can't bring in \(name)", error: error, changedNothing: true)
            }
            preparingIntegration = nil
        }
    }

    /// Runs the merge or the rebase that was asked about.
    func confirmIntegration() {
        guard let pendingIntegration else { return }
        self.pendingIntegration = nil
        integrate(pendingIntegration.integration)
    }

    private func integrate(_ integration: BranchIntegration) {
        let other = Self.shortened(Ref.shortName(integration.ref))
        let here = integration.branch.map { Self.shortened(Ref.shortName($0)) } ?? "HEAD"
        let action: Action
        let title: String
        let message: String
        let done: String
        switch integration.way {
        case .merge:
            (action, title, message, done) = (.merging, "Can't merge \(other) into \(here)", "Roga: before merging \(other) into \(here)", "Merged \(other)")
        case .fastForward:
            (action, title, message, done) = (.fastForwarding, "Can't fast-forward \(here)", "Roga: before fast-forwarding \(here) to \(other)", "Fast-forwarded to \(other)")
        case .rebase:
            (action, title, message, done) = (.rebasing, "Can't rebase \(here) onto \(other)", "Roga: before rebasing \(here) onto \(other)", "Rebased onto \(other)")
        }
        runMove(
            action,
            failure: title,
            move: integration.move,
            message: message,
            arguments: integration.arguments,
            done: done,
            isOwnWork: true,
            before: { [session, worktree] in try await session.checkHead(of: integration, in: worktree) },
            work: { [session, worktree] in try await session.integrate(integration, in: worktree) }
        )
    }

    /// Applies a commit to the branch.
    ///
    /// - Parameter select: Hears the new commit.
    func cherryPick(_ pick: CommitCherryPick, select: @escaping (ObjectID) -> Void) {
        let short = String(pick.commit.hex.prefix(8))
        runMove(
            .cherryPicking,
            failure: "Can't cherry-pick \(short)",
            move: .cherryPick(pick.commit),
            message: "Roga: before cherry-picking \(short)",
            arguments: pick.arguments,
            done: "Cherry-picked \(short)",
            isOwnWork: true,
            work: { [session, worktree] in select(try await session.cherryPick(pick, in: worktree)) }
        )
    }

    /// Whether git will rebase for this pull, which makes it refuse any uncommitted
    /// change rather than only the ones its commits would overwrite. A fast-forward
    /// rebases too when the config says to.
    private func rebases(_ pull: Pull) -> Bool {
        switch pull {
        case .rebase: true
        case .merge: false
        case .fastForward, .configured: status?.pullRebase.map { !["false", "no", "off", "0"].contains($0.lowercased()) } ?? false
        }
    }

    /// Goes to a commit the way `commitSwitch` says. Uncommitted changes that git
    /// would refuse to overwrite go aside and come back afterward (decision 59).
    ///
    /// - Returns: What the title row says about that, or nil when there's nothing
    ///   to say, or a dialog says it.
    /// - Throws: What git said when it refused, once the changes are back where
    ///   they were.
    func go(_ commitSwitch: CommitSwitch) async throws -> String? {
        var move: ChangesAside.Move?
        var message = ""
        switch commitSwitch.way {
        case .movingBranch(let name) where commitSwitch.mode == .keep:
            move = .reset(to: commitSwitch.commit)
            message = "Roga: before resetting \(Ref.shortName(name)) to \(commitSwitch.shortCommit)"
        case .movingBranch:
            // `--soft` and `--mixed` leave the files alone, and `--hard` overwrites
            // them because someone said to, so nothing can be in the way.
            break
        case .detaching:
            move = .detach(at: commitSwitch.commit)
            message = "Roga: before switching to \(commitSwitch.shortCommit)"
        }
        var aside: ChangesAside?
        if let move { aside = try await session.setAsideChanges(inTheWayOf: move, message: message, in: worktree) }
        do {
            try await session.run(commitSwitch, in: worktree)
        } catch {
            try await putBack(afterRefusing: error, aside)
            throw error
        }
        guard let aside else { return nil }
        return try await putBack(aside, ran: [ChangesAside.arguments(message: message), commitSwitch.arguments], done: nil)
    }

    /// Puts back changes that were set aside for a move git refused, which left
    /// `HEAD` where they fit.
    ///
    /// - Throws: `RefusedWithChangesAside` when they couldn't go back.
    private func putBack(afterRefusing refusal: any Error, _ aside: ChangesAside?) async throws {
        guard let aside else { return }
        if (try? await session.putBack(aside, in: worktree)) != .back {
            throw RefusedWithChangesAside(refusal: refusal, aside: aside)
        }
    }

    /// Puts back changes that were set aside for a move that went through.
    ///
    /// - Parameters:
    ///   - ran: What ran so far, for the dialog when they come back with conflicts.
    ///   - done: What the title row says about the move, if anything.
    /// - Returns: What the title row says, or nil when a dialog says how it went.
    private func putBack(_ aside: ChangesAside, ran: [[String]], done: String?) async throws -> String? {
        switch try await session.putBack(aside, in: worktree) {
        case .back:
            return done.map { "\($0) · your changes are back" } ?? "Your changes are back"
        case .conflicted(let files):
            putBackConflict = PutBackConflict(aside: aside, files: files, ran: ran + [ChangesAside.putBackArguments])
            return nil
        case .stillAside(let popped, let said):
            failure = Self.stillAside(aside, ran: popped, said: said)
            return nil
        }
    }

    /// Says that git wouldn't put changes back, such as when an agent wrote to one
    /// of the files meanwhile, so they're still in the stash.
    private static func stillAside(_ aside: ChangesAside, ran: [String], said: String) -> Failure {
        var failure = Failure(title: "Your changes are still in a stash", message: said, command: ran)
        failure.summary = .sentences([
            "git wouldn't put your uncommitted changes back over what's in the worktree now, so they're in the stash \(code: aside.message), and nothing is lost.",
            "What git said is below.",
        ])
        return failure
    }

    /// Goes back to before the pull or the revert that stopped on a conflict, and
    /// puts back any changes that were set aside for the pull.
    func undoConflict() {
        guard let conflict else { return }
        self.conflict = nil
        let what = conflict.startedByPull ? "pull" : conflict.work.noun
        run(.undoing, failure: "Can't undo the \(what)") { [session, worktree] in
            guard let aside = conflict.aside else {
                try await session.abort(conflict.work, in: worktree)
                return "Undid the \(what)"
            }
            let putBack = try await session.undo(puttingBack: aside, stopped: conflict.work, in: worktree)
            return self.finishUndoing(what, putBack, aside)
        }
    }

    /// Goes back to before a move whose changes came back with conflicts, and puts
    /// them back there.
    func undoPutBack() {
        guard let conflict = putBackConflict else { return }
        putBackConflict = nil
        run(.undoing, failure: "Can't undo the \(conflict.noun)") { [session, worktree] in
            let putBack = try await session.undo(puttingBack: conflict.aside, stopped: nil, in: worktree)
            return self.finishUndoing(conflict.noun, putBack, conflict.aside)
        }
    }

    /// What the title row says once an undo has put the changes back, or nil when
    /// a dialog says they couldn't go back.
    private func finishUndoing(_ what: String, _ putBack: ChangesAside.PutBack, _ aside: ChangesAside) -> String? {
        switch putBack {
        case .back:
            return "Undid the \(what)"
        case .conflicted(let files):
            // Only something writing to the files meanwhile could do this.
            putBackConflict = PutBackConflict(aside: aside, files: files, ran: [ChangesAside.putBackArguments])
            return nil
        case .stillAside(let ran, let said):
            failure = Self.stillAside(aside, ran: ran, said: said)
            return nil
        }
    }

    /// Asks whether to abort the merge, rebase or revert the worktree is partway
    /// through.
    func askToAbort() {
        guard !isBusy, let work = unfinished?.work else { return }
        pendingAbort = work
    }

    /// Aborts what someone agreed to abort.
    func confirmAbort() {
        guard let work = pendingAbort else { return }
        pendingAbort = nil
        run(.aborting, failure: "Can't abort") { [session, worktree] in
            try await session.abort(work, in: worktree)
            return work.abortedNote
        }
    }

    // MARK: Pushing

    /// Pushes the way clicking `↑` does.
    func push() {
        guard let push = status?.push else { return }
        run(.pushing, failure: "Can't push \(branchName)", changesNothing: true, fetchesAfterFailing: true) { [session, worktree] in
            try await session.push(push, in: worktree)
            return "Pushed"
        }
    }

    /// Finds out what a force push would overwrite, and asks about that.
    func askToForcePush() {
        guard !isBusy, let status, let upstream = status.upstream else { return }
        preview(nil)
        Task {
            let overwritten = (try? await session.commits(from: "HEAD", to: upstream, limit: Self.overwrittenLimit, in: worktree)) ?? []
            forcePush = ForcePush(
                branch: Ref.shortName(status.branch),
                upstream: Ref.shortName(upstream),
                count: status.behind,
                commits: await listed(overwritten)
            )
        }
    }

    /// What a dialog needs to name commits.
    func listed(_ ids: [ObjectID]) async -> [ListedCommit] {
        let commits = (try? await session.commits(ids)) ?? []
        return commits.compactMap { $0.map(ListedCommit.init) }
    }

    /// Runs the force push that was asked about.
    func confirmForcePush() {
        forcePush = nil
        run(.forcePushing, failure: "Can't force push \(branchName)", changesNothing: true, fetchesAfterFailing: true) { [session, worktree] in
            try await session.push(.forceWithLease, in: worktree)
            return "Pushed"
        }
    }

    /// Pushes the branch so that its commits aren't lost, then goes to a commit. If
    /// the push is refused, nothing else happens.
    func push(thenGoingTo commitSwitch: CommitSwitch) {
        guard let push = status?.push else { return }
        run(.pushing, failure: "Can't push \(branchName)", changesNothing: true, fetchesAfterFailing: true) { [session, worktree, weak self, branchName] in
            try await session.push(push, in: worktree)
            var note: String?
            do {
                note = try await self?.go(commitSwitch)
            } catch {
                var failure = Failure(title: commitSwitch.failureTitle, error: error)
                let stayed: DialogText = "The push went through, but \(code: branchName) is still where it was."
                failure.summary = error.gitArguments == nil ? stayed : .sentences([stayed, "What git said is below."])
                self?.failure = failure
                return nil
            }
            return note == nil ? "Pushed" : "Pushed · your changes are back"
        }
    }

    /// Pushes a branch other than the one checked out.
    ///
    /// - Parameters:
    ///   - name: The branch's full name.
    ///   - upstream: What it tracks, or nil to push it for the first time.
    func push(branch name: String, upstream: RefRelation.Upstream?) {
        let short = Ref.shortName(name)
        let push: Push
        if let upstream, let remote = upstream.remote {
            push = .otherBranch(short, remote: remote, onRemote: upstream.branchOnRemote == short ? nil : upstream.branchOnRemote)
        } else if upstream == nil, let remote = status?.pushRemote {
            push = .otherBranchFirstTime(short, remote: remote)
        } else {
            return
        }
        run(.pushing, failure: "Can't push \(short)", changesNothing: true, fetchesAfterFailing: true) { [session, worktree] in
            try await session.push(push, in: worktree)
            return "Pushed \(Self.shortened(short))"
        }
    }

    /// Fast-forwards a branch other than the one checked out to its upstream, by
    /// their full names.
    func fastForward(branch name: String, toUpstream upstream: String) {
        let short = Ref.shortName(name)
        run(.pulling, failure: "Can't fast-forward \(short)", changesNothing: true) { [session, worktree] in
            try await session.fastForward(branch: name, to: upstream, in: worktree)
            return "Fast-forwarded \(Self.shortened(short))"
        }
    }

    // MARK: Deleting branches

    /// Deletes a branch or remote branch straight away when that loses nothing,
    /// and otherwise says what it would lose and asks. Deleting from a remote
    /// always asks, because that affects everyone who uses the remote.
    ///
    /// - Parameter name: The branch's full name.
    func askToDelete(ref name: String) {
        guard !isBusy else { return }
        preparingDeletion = Task {
            do {
                let deletion = try await session.prepareToDelete(ref: name, limit: Self.overwrittenLimit, in: worktree)
                if deletion.asksFirst {
                    pendingDeletion = PendingDeletion(deletion: deletion, commits: await listed(deletion.lost))
                } else {
                    delete(deletion)
                }
            } catch {
                failure = Failure(title: "Can't delete \(Ref.shortName(name))", error: error, changedNothing: true)
            }
            preparingDeletion = nil
        }
    }

    /// Asks which of the branches on a commit should go, which is the one way history's
    /// menu deletes anything, so this always opens a dialog. With only one branch that
    /// can go there's nothing to choose, so it only asks about that one. With none, git
    /// says who has it checked out, which says more than anything here could.
    ///
    /// - Parameters:
    ///   - names: The full names of all the branches on the commit.
    ///   - commit: The commit they're on.
    func askToDelete(branches names: [String], on commit: ObjectID) {
        guard !isBusy else { return }
        preparingDeletion = Task {
            do {
                let deletion = try await session.prepareToDelete(branches: names, on: commit, limit: Self.overwrittenLimit, in: worktree)
                if deletion.branches.count > 1 {
                    branchChoice = BranchChoice(deletion: deletion, commits: await listed(deletion.lost))
                } else if let only = deletion.branches.first {
                    pendingDeletion = PendingDeletion(deletion: only, commits: await listed(only.lost), checkedOut: deletion.checkedOut.map(\.shortName))
                } else if let checkedOut = deletion.checkedOut.first {
                    delete(checkedOut)
                } else {
                    failure = Failure(
                        title: "Nothing to delete",
                        message: "The branches on this commit have moved or gone since history last looked.",
                        changedNothing: true
                    )
                    lookAgain()
                }
            } catch {
                failure = Failure(title: "Can't delete branches", error: error, changedNothing: true)
            }
            preparingDeletion = nil
        }
    }

    /// Deletes what was picked, stopping at anything git refuses. Remotes go last, so
    /// that git refusing a branch stops everything before anyone else sees a change.
    func confirmBranchChoice() {
        guard let choice = branchChoice else { return }
        let deletions = choice.deletions
        guard let first = deletions.first else { return }
        branchChoice = nil
        let action: Action? = deletions.contains(where: \.reachesRemote) ? .deletingFromRemote : nil
        run(action, failure: "Can't delete \(first.shortName)", changesNothing: true) { [session, worktree, weak self] in
            try await session.delete(first, in: worktree)
            for (index, deletion) in deletions.enumerated().dropFirst() {
                do {
                    try await session.delete(deletion, in: worktree)
                } catch {
                    let gone = deletions[..<index].map(\.shortName)
                    let left = deletions[index...].map(\.shortName)
                    var failure = Failure(title: "Can't delete \(deletion.shortName)", error: error)
                    failure.summary = "\(Self.list(gone)) \(gone.count == 1 ? "is" : "are") gone, but \(Self.list(left)) \(left.count == 1 ? "isn't" : "aren't"). What git said is below."
                    self?.failure = failure
                    return nil
                }
            }
            return deletions.count == 1 ? "Deleted \(Self.shortened(first.shortName))" : "Deleted \(deletions.count.formatted()) branches"
        }
    }

    /// Names in a sentence, as in `a, b and c`.
    private static func list(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Runs the deletion that was asked about.
    func confirmDeletion() {
        guard let pendingDeletion else { return }
        self.pendingDeletion = nil
        delete(pendingDeletion.deletion)
    }

    /// Runs a deletion. Only a remote takes long enough for the house, and leaving
    /// it out lets someone delete several branches in a row without waiting for it.
    private func delete(_ deletion: BranchDeletion) {
        var action: Action?
        if case .remote = deletion.place { action = .deletingFromRemote }
        run(action, failure: "Can't delete \(deletion.shortName)", changesNothing: true) { [session, worktree] in
            try await session.delete(deletion, in: worktree)
            return "Deleted \(Self.shortened(deletion.shortName))"
        }
    }

    /// A branch's name, short enough to say what just happened in the title row,
    /// which keeps that at its full width. Names usually differ at their ends.
    static func shortened(_ name: String) -> String {
        name.count <= 32 ? name : name.prefix(15) + "…" + name.suffix(16)
    }

    // MARK: New branches

    /// Makes a new branch, and shows its worktree if it gets one.
    ///
    /// - Returns: What git said if it refused, which the popover shows.
    func create(_ branch: NewBranch, showWorktree: @escaping (String, ObjectID?) -> Void) async -> String? {
        guard !isBusy else { return nil }
        do {
            try await session.create(branch, in: worktree)
        } catch {
            return (error as? GitError)?.message ?? String(describing: error)
        }
        isCreatingBranch = false
        // The window can only show a worktree the sidebar knows about.
        await reportBranchChange()
        lookAgain()
        if branch.inNewWorktree,
           let created = try? await session.worktrees().first(where: { $0.branch == Ref.branchPrefix + branch.name }) {
            showWorktree(created.path, created.head)
        }
        return nil
    }

    /// Makes a tag.
    ///
    /// - Returns: What git said if it refused, which the popover shows.
    func create(_ tag: NewTag) async -> String? {
        guard !isBusy else { return nil }
        do {
            try await session.create(tag, in: worktree)
        } catch {
            return (error as? GitError)?.message ?? String(describing: error)
        }
        newTagStart = nil
        lookAgain()
        return nil
    }

    // MARK: Running

    /// Runs what someone asked for, unless something's running already, and
    /// looks at what it changed.
    ///
    /// - Parameters:
    ///   - action: What the title row shows while it runs, or nil for something
    ///     too quick to mention, which doesn't wait for the house.
    ///   - title: What a dialog's title says when git refuses.
    ///   - changesNothing: Whether a refusal leaves everything as it was, so that
    ///     the dialog can say so.
    ///   - fetchesAfterFailing: Whether a refusal may mean the counts were stale,
    ///     as a rejected push does, so a fetch should correct them.
    ///   - work: Returns what to say when it's done, if anything.
    func run(
        _ action: Action?,
        failure title: String,
        changesNothing: Bool = false,
        fetchesAfterFailing: Bool = false,
        work: @escaping () async throws -> String?
    ) {
        guard !isBusy else { return }
        // The count under the pointer is about to go, and it won't say the
        // pointer has left.
        preview(nil)
        self.action = action
        finished = nil
        undoFinished = nil
        let started = ContinuousClock.now
        running = Task {
            do {
                if let message = try await work() {
                    // A quick git shouldn't cut the house off partway through.
                    // Bad news doesn't wait for it.
                    if let action { try? await Task.sleep(until: started + timeToPlayHouse(action), clock: .continuous) }
                    show(finished: message)
                }
            } catch {
                failure = Failure(title: title, error: error, changedNothing: changesNothing)
                if fetchesAfterFailing, fetchesByItself(), let remote = status?.remote {
                    fetchRecord = await session.fetchQuietly(from: remote, minimumInterval: .zero)
                }
            }
            fetchRecord = await session.lastFetch()
            self.action = nil
            running = nil
            lookAgain()
            await reportBranchChange()
        }
    }

    /// The button that takes back what the title row says just happened.
    struct FinishedUndo {
        /// What its tooltip says.
        let help: String
        let perform: () -> Void
    }

    /// Says in the title row what just happened, when it didn't go through `run`.
    func announce(_ message: String, undo: FinishedUndo?) {
        undoFinished = undo
        show(finished: message)
    }

    private func show(finished message: String) {
        finished = message
        finishedNote?.cancel()
        let duration = timeToShowFinished(undoFinished != nil)
        finishedNote = Task {
            guard (try? await Task.sleep(for: duration)) != nil else { return }
            finished = nil
            undoFinished = nil
        }
    }

    // MARK: Previewing

    /// Tints the commits that a count would move while the pointer is over it, or
    /// none once it has left.
    func preview(_ direction: Direction?) {
        previewing?.cancel()
        guard let direction, let upstream = status?.upstream else {
            showPreview([])
            return
        }
        let (base, tip) = direction == .pull ? ("HEAD", upstream) : (upstream, "HEAD")
        previewing = Task {
            let ids = (try? await session.commits(from: base, to: tip, limit: Self.previewLimit, in: worktree)) ?? []
            if !Task.isCancelled { showPreview(ids) }
        }
    }

    // MARK: What the title row says

    /// The tooltip of `↓`, which says what clicking it would do.
    var pullHelp: String {
        guard let status else { return "" }
        let upstream = upstreamName ?? ""
        guard let pull = status.pull else {
            return "\(branchName) has diverged from \(upstream). Click to choose whether to rebase or merge."
        }
        return "\(Self.commits(status.behind, "Pull")) from \(upstream) into \(branchName)\n\(Self.command(pull.arguments))"
    }

    /// The tooltip of `↑`, which says what clicking it would do.
    var pushHelp: String {
        guard let status else { return "" }
        guard let push = status.push else {
            return "\(branchName) is behind \(upstreamName ?? "its upstream"), so git would reject a push. Click for what you can do."
        }
        if case .firstTime(let remote) = push {
            return "Push \(branchName) to \(remote) for the first time\n\(Self.command(push.arguments))"
        }
        return "\(Self.commits(status.ahead, "Push")) from \(branchName) to \(upstreamName ?? "")\n\(Self.command(push.arguments))"
    }

    /// The tooltip of the Fetch button: where it fetches from, when Roga last
    /// did, and the command.
    func fetchHelp(now: Date = Date()) -> String {
        guard let remote = status?.remote else { return "No remote to fetch from" }
        var lines = [isFetching ? "Fetching from \(remote)…" : "Fetch from \(remote)"]
        let fetched = fetchRecord.lastFetched.map { "Last fetched " + Self.age(of: $0, now: now) }
        if let failure = fetchRecord.failure, !failure.isEmpty, !isFetching {
            lines.append(["Couldn't reach \(remote)", fetched].compactMap(\.self).joined(separator: ". "))
        } else if let fetched, !isFetching {
            lines.append(fetched)
        }
        lines.append(Self.command(RepositorySession.fetchArguments(from: remote)))
        return lines.joined(separator: "\n")
    }

    private static func commits(_ count: Int, _ verb: String) -> String {
        count == 1 ? "\(verb) 1 commit" : "\(verb) \(count.formatted()) commits"
    }

    /// A command as someone would type it.
    static func command(_ arguments: [String]) -> String {
        ShellCommand.text(arguments)
    }

    /// The first line of the branch's menu: its upstream, how far the branch is
    /// from it, and when Roga last fetched.
    func summary(now: Date = Date()) -> String {
        var parts: [String] = []
        if let failure = fetchRecord.failure, !failure.isEmpty, !isFetchingByItself, action != .fetching, let remote = status?.remote {
            parts.append("couldn't reach \(remote)")
        } else if let status {
            if let upstream = status.upstream {
                parts.append(Ref.shortName(upstream))
                switch (status.behind, status.ahead) {
                case (0, 0): parts.append("up to date")
                case (let behind, 0): parts.append("\(behind.formatted()) behind")
                case (0, let ahead): parts.append("\(ahead.formatted()) ahead")
                case (let behind, let ahead): parts.append("\(behind.formatted()) behind, \(ahead.formatted()) ahead")
                }
            } else if status.upstreamIsGone {
                parts.append("its upstream is gone")
            } else if status.pushRemote != nil {
                parts.append("not pushed yet")
            } else {
                parts.append("no remote")
            }
        }
        if isFetchingByItself || action == .fetching {
            parts.append("fetching…")
        } else if let date = fetchRecord.lastFetched {
            parts.append("fetched " + Self.age(of: date, now: now))
        }
        return parts.joined(separator: " · ")
    }

    /// As in `4 min ago`.
    static func age(of date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86400) d ago"
        }
    }
}
