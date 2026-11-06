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
            self.init(title: title, message: error.dialogMessage, command: error.gitArguments, changedNothing: changedNothing)
        }

        init(title: String, message: String, command: [String]? = nil, changedNothing: Bool = false) {
            self.title = title
            self.message = message
            self.command = command
            self.changedNothing = changedNothing
        }
    }

    /// A pull or a revert that hit a conflict, which Roga can't resolve, so it asks
    /// whether to undo it or leave it for the command line.
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

        /// Whether a pull stopped, rather than a revert.
        var startedByPull: Bool {
            if case .revert = work { false } else { true }
        }
    }

    /// A force push that's waiting for someone to agree to what it overwrites.
    struct ForcePush: Equatable {
        var branch: String
        var upstream: String
        /// How many commits it overwrites, and the first few.
        var count: Int
        var commits: [ListedCommit]
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
    /// Whether Roga is fetching by itself, which only the branch's menu mentions.
    private(set) var isFetchingByItself = false
    /// What git is doing because someone asked it to.
    private(set) var action: Action?
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
    /// A pull that needs someone to choose between rebasing and merging.
    var pullChoice: PullChoice?
    /// What the worktree is stuck partway through, whoever started it, which
    /// takes the place of the counts. The worktree's model keeps this current.
    var unfinished: UnfinishedWork?
    /// A merge, a rebase or a revert that's waiting for someone to agree to abort it.
    var pendingAbort: StoppedWork?
    /// A force push that's waiting for someone to agree to it.
    var forcePush: ForcePush?
    /// A deletion that's waiting for someone to agree to it.
    var pendingDeletion: PendingDeletion?
    /// A deletion that's waiting for someone to choose what goes.
    var branchChoice: BranchChoice?
    /// Whether the popover for a new branch shows.
    var isCreatingBranch = false
    /// Whether that popover starts with In a new worktree checked, as it does
    /// from the menu of the repository's worktrees.
    var startsInNewWorktree = false

    /// Shows the popover for a new branch, ready to make it in a new worktree.
    func startNewWorktree() {
        guard !isBusy else { return }
        startsInNewWorktree = true
        isCreatingBranch = true
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
    /// Asks the worktree's model to select the row for uncommitted changes.
    @ObservationIgnored var showChanges: () -> Void = {}
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

    /// Fetches because someone asked to.
    func fetch() {
        guard let remote = status?.remote else { return }
        run(.fetching, failure: "Can't fetch from \(remote)") { [session, worktree] in
            try await session.fetch(from: remote, in: worktree)
            return "Fetched"
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
        run(.pulling, failure: "Can't pull \(branchName)", changesNothing: true) { [session, worktree] in
            if remembering { try await session.remember(pull, in: worktree) }
            let wasStopped = (try? await session.stoppedWork(in: worktree)) != nil
            do {
                try await session.pull(pull, in: worktree)
            } catch {
                // git hit a conflict just now, so this is the pull's own mess to
                // clean up, rather than one that was there already.
                if !wasStopped, let stopped = try? await session.stoppedWork(in: worktree) {
                    let status = try? await session.status(in: worktree)
                    self.conflict = Conflict(work: stopped, files: status?.conflicted.map(\.path) ?? [], ran: error.gitArguments)
                    return nil
                }
                throw error
            }
            return "Pulled"
        }
    }

    /// Goes back to before the pull or the revert that stopped on a conflict.
    func undoConflict() {
        guard let conflict else { return }
        self.conflict = nil
        let what = conflict.startedByPull ? "pull" : conflict.work.noun
        run(.undoing, failure: "Can't undo the \(what)") { [session, worktree] in
            try await session.abort(conflict.work, in: worktree)
            return "Undid the \(what)"
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
            do {
                try await session.run(commitSwitch, in: worktree)
            } catch {
                var failure = Failure(title: commitSwitch.failureTitle, error: error)
                let stayed: DialogText = "The push went through, but \(code: branchName) is still where it was."
                failure.summary = error.gitArguments == nil ? stayed : .sentences([stayed, "What git said is below."])
                self?.failure = failure
                return nil
            }
            return "Pushed"
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
