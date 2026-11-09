import CommitGraph
import DiffUI
import Foundation
import GitCore
import GitRunner
import HistoryUI
import Observation
import RepositoryEngine

/// Connects a worktree's history, from its repository's session, to the
/// views that show it.
@Observable
final class RepositoryModel {
    enum Phase {
        case loading
        case ready
        case failed(String)

        /// Whether history and the panels under it show.
        var isReady: Bool {
            if case .ready = self { true } else { false }
        }
    }

    /// What history to load: in which order, and how many times the user
    /// asked to load it again.
    struct LoadRequest: Equatable {
        var sort: HistoryOrder.Sort
        var reloads: Int
    }

    /// A branch that couldn't be checked out, and what git said about it.
    struct CheckoutFailure: Equatable {
        var branch: String
        var message: String
        /// What ran, by its arguments after `git`.
        var command: [String]? = nil
    }

    /// Going to a commit that's waiting for someone to agree to what it loses.
    struct PendingCommitSwitch {
        /// A branch's badge, when checking that out is what leaves the commits behind.
        struct Checkout {
            /// The local branch's short name.
            var branch: String
            var run: () async -> Void
        }

        var commitSwitch: CommitSwitch
        /// The newest commits it loses.
        var commits: [ListedCommit]
        var checkout: Checkout? = nil
    }

    /// Where the repository's commit-graph files stand (decision 6).
    enum CommitGraphState: Equatable {
        case unknown
        case updating
        case finished(CommitGraphUpdate)
        /// The user turned off keeping the files up to date.
        case turnedOff
        /// git couldn't write the files. The message says why.
        case failed(String)
    }

    /// How many commits it takes for loading history without commit-graph
    /// files to be slow enough to mention. Linux's 1.5 million take about 21
    /// seconds, so this many take about 0.7.
    static let largeHistory = 50_000

    let session: RepositorySession
    /// The worktree's folder.
    let worktree: String
    private(set) var phase = Phase.loading
    private(set) var history: History?
    /// Goes up each time `history` changes, so the commit list knows to show
    /// the new rows.
    private(set) var historyVersion = 0
    var sort = HistoryOrder.Sort.topological
    /// Goes up when the user asks to load history again.
    private(set) var reloads = 0
    private(set) var commitGraphState = CommitGraphState.unknown
    /// The commit selected in history, and what the commit panel shows of it.
    let selectedCommit: SelectedCommit
    /// The worktree's uncommitted changes, when their row is selected.
    let selectedChanges: SelectedChanges
    /// What the refs panel lists.
    let refs: RefsModel
    /// The branch in the title row, and what can be done with it.
    let branch: BranchModel
    /// Asking an agent about something git refused (decision 63).
    let gitFix: GitFixModel
    /// Goes up when the refs panel should read its lists again, if it's showing.
    private(set) var refsChecks = 0
    /// How many files have uncommitted changes. While there are any, a row for
    /// them comes before the first commit.
    private(set) var uncommittedFiles = 0
    /// How many of them have staged changes, which their row says too.
    private(set) var stagedFiles = 0
    /// The message of the next commit, and making it.
    let composer: CommitComposer
    /// The selected rows: usually one, and several when commits are picked
    /// together or a branch is reviewed (decision 56). It's empty while the
    /// history being loaded hasn't reached the selected commit yet, and the commit
    /// stays selected, and while a stash shows.
    private(set) var selectedRows = IndexSet()
    /// The commit history marks while the panels show what it's the base of, such
    /// as a branch's merge base or the commit a stash was made on, and what the
    /// mark says.
    private(set) var mark: (commit: ObjectID, title: String)?
    /// The branch being checked out, once that's taken long enough to mention.
    private(set) var slowCheckout: String?
    /// What to tell the user about a checkout that didn't work, until they've
    /// seen it.
    var checkoutFailure: CheckoutFailure?
    /// Going to a commit that's waiting for someone to agree to it.
    var pendingCommitSwitch: PendingCommitSwitch?
    /// Reverting a commit, while someone chooses whether to commit it.
    var pendingRevert: CommitRevert?
    /// Moving the branch to a commit, while someone chooses how far that goes.
    var pendingReset: PendingReset?
    /// Applying a commit that's waiting for someone to agree to it.
    var pendingCherryPick: CommitCherryPick?

    /// The request whose history has loaded completely.
    @ObservationIgnored private var loaded: LoadRequest?
    /// The text of commits the list has drawn, by position. Positions belong
    /// to one loaded graph, so the text goes when another graph arrives.
    @ObservationIgnored private var texts: [CommitGraph.Position: RowText] = [:]
    @ObservationIgnored private var graphGeneration = 0
    @ObservationIgnored private var badges: [CommitGraph.Position: [CommitRowContent.Badge]] = [:]
    /// The commits that the count under the pointer would move, which history
    /// tints.
    @ObservationIgnored private var previewedCommits: Set<CommitGraph.Position> = []
    /// The commits of the selected rows while there's more than one, from the
    /// newest, so that they can be found again when history loads.
    @ObservationIgnored private var selectedCommits: [ObjectID] = []
    /// Where the marked commit is in the loaded graph.
    @ObservationIgnored private var markedPosition: CommitGraph.Position?
    /// What branches are reviewed against: the main branch and its upstream, by
    /// their full names, and the main branch's short name. It's observed, so that
    /// the refs panel's buttons show once history knows the main branch.
    private var reviewMain: (refs: [String], title: String)?
    /// Reading what's needed for a review or a stash, which selecting something
    /// else cancels.
    @ObservationIgnored private(set) var selecting: Task<Void, Never>?
    @ObservationIgnored private let now = Date()
    /// Whether the user wants commit-graph files kept up to date.
    @ObservationIgnored private let keepsCommitGraphCurrent: () -> Bool
    /// Says how many files are uncommitted, whenever that's been checked.
    @ObservationIgnored private let reportUncommittedFiles: (Int) -> Void
    /// Says whether the worktree has conflicts, whenever that's been checked.
    @ObservationIgnored private let reportConflicts: (Bool) -> Void
    /// Says that the worktree is on another branch, or the repository has a new
    /// worktree, because of something Roga did, and returns once the sidebar knows.
    @ObservationIgnored private let reportBranchChange: () async -> Void
    /// The line from the row for uncommitted changes down to `HEAD`.
    @ObservationIgnored private var workingTreeLine: WorkingTreeLine?
    /// Whether the row for uncommitted changes should be selected once it's there,
    /// as after undoing a commit that left no row behind.
    @ObservationIgnored private var selectsChangesWhenTheyShow = false
    /// The check that Roga becoming active started, which a newer one replaces.
    @ObservationIgnored private(set) var check: Task<Void, Never>?
    /// What changed on disk that the next look reads.
    @ObservationIgnored private var diskChanges = DiskChanges()
    /// The look at what changed on disk that's running. Unlike `check`, a newer
    /// one never replaces it, because changes that keep coming would then stop
    /// every `git status` before it finished.
    @ObservationIgnored private(set) var diskLook: Task<Void, Never>?
    /// When the last look at changes on disk started and finished, which the
    /// next one waits for, as `ChangePacing` says.
    @ObservationIgnored private var lastDiskLook: (started: ContinuousClock.Instant, finished: ContinuousClock.Instant)?

    /// What changed on disk since the model last looked.
    private struct DiskChanges {
        /// The latest change to the worktree's uncommitted files, by its number.
        var files: Int?
        /// The latest change that moved a ref or `HEAD`, by its number.
        var refs: Int?

        var isEmpty: Bool { files == nil && refs == nil }
    }
    /// The running update of the commit-graph files, which isn't tied to any
    /// view, so that it carries on when the window shows another worktree.
    @ObservationIgnored private(set) var commitGraphUpdate: Task<Void, Never>?
    /// The running checkout. It isn't tied to any view either, because cancelling
    /// it would stop git while it may be writing the worktree's files.
    @ObservationIgnored private(set) var checkout: Task<Void, Never>?
    /// Finding out what reverting a commit would come to.
    @ObservationIgnored private(set) var preparingRevert: Task<Void, Never>?
    /// Finding out what resetting to a commit or applying one would come to.
    @ObservationIgnored private(set) var preparingAction: Task<Void, Never>?
    /// How every branch stands against the commit `HEAD` was on, for the menus.
    @ObservationIgnored private var refRelations: (head: ObjectID, relations: [String: RefRelation])?
    @ObservationIgnored private(set) var refRelationsUpdate: Task<Void, Never>?
    /// The repository's remotes, from A to Z, as of the last time history loaded.
    @ObservationIgnored private(set) var remoteNames: [String] = []

    private struct RowText {
        var subject: String
        var body: String
        var author: String
        var date: String
    }

    /// The most commits whose text is kept. Text for others is read again
    /// when they scroll back into view, which takes about a millisecond for
    /// a screen.
    private static let textLimit = 20_000

    init(
        session: RepositorySession,
        worktree: String,
        keepsCommitGraphCurrent: @escaping () -> Bool = { UserDefaults.standard.keepsCommitGraphCurrent },
        reportUncommittedFiles: @escaping (Int) -> Void = { _ in },
        reportConflicts: @escaping (Bool) -> Void = { _ in },
        reportBranchChange: @escaping () async -> Void = {},
        fetchesByItself: @escaping () -> Bool = { UserDefaults.standard.fetchesByItself },
        drafts: CommitDrafts = .standard,
        generators: MessageGenerators = .shared
    ) {
        self.session = session
        self.worktree = worktree
        self.keepsCommitGraphCurrent = keepsCommitGraphCurrent
        self.reportUncommittedFiles = reportUncommittedFiles
        self.reportConflicts = reportConflicts
        self.reportBranchChange = reportBranchChange
        selectedCommit = SelectedCommit(session: session)
        selectedChanges = SelectedChanges(session: session, worktree: worktree, selectedFile: selectedCommit.selectedFile, fileList: selectedCommit.fileList)
        refs = RefsModel(session: session, worktree: worktree)
        branch = BranchModel(session: session, worktree: worktree, fetchesByItself: fetchesByItself, reportBranchChange: reportBranchChange)
        gitFix = GitFixModel(session: session, worktree: worktree)
        composer = CommitComposer(session: session, worktree: worktree, branch: branch, changes: selectedChanges, drafts: drafts, generators: generators)
        selectedChanges.onLoad = { [weak self] changes in self?.show(uncommittedFiles: changes.fileCount, staged: changes.staged.count) }
        selectedChanges.onFailure = { [weak branch] title, error in branch?.failure = BranchModel.Failure(title: title, error: error, changedNothing: true) }
        selectedChanges.onDiscard = { [weak self] words, canUndo in
            guard let self else { return }
            let undo = BranchModel.FinishedUndo(help: "Undo the Discard") { [weak self] in self?.selectedChanges.undoDiscard() }
            branch.announce(words, undo: canUndo ? undo : nil)
        }
        selectedChanges.canDiscardEverything = { [weak branch] in
            guard let branch else { return false }
            return !branch.isBusy && branch.unfinished == nil
        }
        selectedChanges.lookAgain = { [weak self] in self?.lookAgain() }
        gitFix.lookAgain = { [weak self] in self?.lookAgain() }
        selectedChanges.showChanges = { [weak self] in self?.selectChangesOnceTheyShow() }
        composer.currentBranch = { [weak self] in self?.history?.refs.currentBranch }
        composer.select = { [weak self] commit in self?.selectNewCommit(commit) }
        composer.showChanges = { [weak self] in self?.selectChangesOnceTheyShow() }
        branch.isCheckingOut = { [weak self] in self?.checkout != nil }
        branch.lookAgain = { [weak self] in self?.lookAgain() }
        branch.remotesChanged = { [weak self] in self?.updateRefRelations(head: self?.history?.refs.head) }
        branch.showConflicts = { [weak self] in
            guard let self, hasWorkingTreeRow else { return }
            selectRow(0)
            // When the row was selected already, another file may be showing.
            // Otherwise this waits for the files, and the first one is a conflict.
            selectedChanges.selectFirstFile()
        }
        branch.showPreview = { [weak self] commits in self?.preview(commits) }
        selectedCommit.selectedFile.nameConflicts = { [weak self] labels in
            guard let self else { return ConflictNaming().sides(oursLabel: labels?.ours ?? "HEAD", theirsLabel: labels?.theirs ?? "") }
            return await nameConflicts(labels)
        }
        branch.stagedFiles = { [weak self] in self?.stagedFiles ?? 0 }
    }

    /// The file selected in whichever panel is showing, which the diff panel
    /// shows.
    var selectedFile: SelectedFile { selectedCommit.selectedFile }

    /// What whichever panel is showing lists of its files.
    var fileList: FileListModel { selectedCommit.fileList }

    /// Whether a panel has files to list, or will have once they're read.
    var canFilterFiles: Bool {
        if selectedChanges.isSelected { return true }
        switch selectedCommit.subject {
        case nil, .scattered: return false
        case .commit, .comparison, .stash: return true
        }
    }

    /// Selects the file `step` places from the selected one.
    func selectFile(by step: Int) {
        if selectedChanges.isSelected {
            selectedChanges.selectFile(by: step)
        } else {
            selectedCommit.selectFile(by: step)
        }
    }

    var loadRequest: LoadRequest { LoadRequest(sort: sort, reloads: reloads) }

    /// The name of the current branch, or a short ID for a detached `HEAD`.
    var headDescription: String? {
        guard let history else { return nil }
        if let branch = history.refs.currentBranch { return Ref.shortName(branch) }
        guard let head = history.refs.head else { return nil }
        return "detached at " + head.hex.prefix(8)
    }

    /// How many commits history has, once it has read them all.
    var commitCountDescription: String? {
        guard let history, history.isComplete else { return nil }
        return history.rows.count == 1 ? "1 commit" : "\(history.rows.count.formatted()) commits"
    }

    /// Names the sides of a conflicted file by where they came from, from the labels
    /// after its first conflict's markers, or from what the worktree is partway
    /// through when it has no markers (decision 60).
    private func nameConflicts(_ labels: (ours: String, theirs: String)?) async -> ConflictSides {
        let work = branch.unfinished?.work
        let oursLabel = labels?.ours ?? "HEAD"
        var theirsLabel = labels?.theirs ?? "Stashed changes"
        if labels == nil, let label = try? await session.incomingConflictLabel(in: worktree) { theirsLabel = label }
        var naming = ConflictNaming(
            branch: history?.refs.currentBranch.map(Ref.shortName),
            head: history?.refs.head,
            work: work,
            refs: history?.refs.refs ?? [],
            upstream: branch.status?.upstream
        )
        if case .rebase = work { naming.onto = try? await session.rebaseOnto(in: worktree) }
        let ids = naming.commitsToDescribe(oursLabel: oursLabel, theirsLabel: theirsLabel)
        if let commits = try? await session.commits(ids) {
            for commit in commits.compactMap(\.self) { naming.subjects[commit.id] = commit.subject }
        }
        return naming.sides(oursLabel: oursLabel, theirsLabel: theirsLabel)
    }

    /// Goes to the row for uncommitted changes, if there is one.
    func goToChanges() {
        guard hasWorkingTreeRow else { return }
        selectRow(0)
        selectedChanges.askForFocus()
    }

    func reload() {
        reloads += 1
        refsChecks += 1
    }

    /// Writes what the repository's commit-graph files are missing, in the
    /// background, unless the user turned that off. History on screen stays
    /// as it is, because the files would only change how quickly it loads.
    func updateCommitGraph() {
        guard keepsCommitGraphCurrent() else {
            commitGraphState = .turnedOff
            return
        }
        guard commitGraphUpdate == nil else { return }
        // An answer stays until there's a new one, which usually takes a
        // moment, so that what the panel says about it doesn't flicker.
        if case .finished = commitGraphState {} else { commitGraphState = .updating }
        commitGraphUpdate = Task {
            do {
                commitGraphState = .finished(try await session.updateCommitGraph())
            } catch is CancellationError {
                commitGraphState = .unknown
            } catch {
                commitGraphState = .failed(String(describing: error))
            }
            commitGraphUpdate = nil
        }
    }

    /// Why history takes long to load without commit-graph files, and what
    /// Roga is doing about it, or nil when there's nothing to say.
    var slowHistoryExplanation: String? {
        let slow = "History loads slowly without a commit-graph file"
        switch commitGraphState {
        case .unknown, .finished(.upToDate), .finished(.written):
            return nil
        case .updating:
            return slow + ". Roga is writing one in the background, so this repository opens faster next time."
        case .turnedOff:
            return slow + ". To have Roga write one, turn on Keep commit-graph files up to date in Settings."
        case .finished(.skipped(let reason)):
            return slow + ", and Roga doesn't write one here. " + reason.description
        case .failed(let message):
            return slow + ", and git couldn't write one. " + message
        }
    }

    /// Whether the history on screen was slow to load because it didn't come
    /// from commit-graph files.
    var historyWasSlowToLoad: Bool {
        guard let history else { return false }
        return !history.readCommitGraphFiles && history.rows.count >= Self.largeHistory
    }

    /// Loads what the window shows of the worktree. It returns when that's
    /// done, or when the task is cancelled, as it is when the order changes or
    /// the window shows another worktree. A worktree that was showing before
    /// has its history already, so it only needs checking.
    func appear() async {
        if loadRequest == loaded {
            await checkForChanges()
        } else {
            async let status: Void = updateUncommittedFiles()
            async let branchStatus: Void = branch.refresh()
            await load()
            await status
            await branchStatus
        }
        if !Task.isCancelled { branch.fetchByItself() }
    }

    /// Fetches, if it's been long enough, because Roga became active (decision
    /// 20). When the session isn't watching the repository, as on a volume that
    /// doesn't record changes, it also looks at the worktree again, because
    /// whatever the user was doing elsewhere may have changed it.
    func becameActive() {
        if !session.isWatching { lookAgain() }
        branch.fetchByItself()
    }

    /// Looks at the worktree again, because something Roga did elsewhere, such as
    /// deleting another worktree and its branch from the sidebar, moved its refs.
    func refsChanged() {
        lookAgain()
    }

    /// Looks at the worktree's uncommitted files again, because they changed on
    /// disk. The list of repositories hears that from the session and passes it on.
    ///
    /// - Parameter change: The change's number, which lets the window share a
    ///   `git status` with the sidebar.
    func filesChangedOnDisk(asNewAs change: Int) {
        diskChanges.files = max(diskChanges.files ?? change, change)
        lookAtDiskChanges()
    }

    /// Looks at the refs and history again, because a ref or a worktree's `HEAD`
    /// moved on disk.
    ///
    /// - Parameter change: The change's number.
    func refsChangedOnDisk(asNewAs change: Int) {
        diskChanges.refs = max(diskChanges.refs ?? change, change)
        lookAtDiskChanges()
    }

    /// Reads what changed on disk, unless a look is running, which then looks
    /// once more when it's done. Changes that keep coming are paced, as
    /// `ChangePacing` says.
    private func lookAtDiskChanges() {
        guard diskLook == nil else { return }
        diskLook = Task {
            while !diskChanges.isEmpty {
                // The look before may have been in another task, since each ends
                // when nothing more changed while it ran.
                if let last = lastDiskLook { await ChangePacing.wait(afterLookFrom: last.started, to: last.finished) }
                let changes = diskChanges
                diskChanges = DiskChanges()
                let started = ContinuousClock.now
                if let refs = changes.refs {
                    refsChecks += 1
                    async let branchStatus: Void = branch.refresh()
                    // A commit moves the branch without always writing the
                    // index, and what's staged compares with the branch's commit.
                    await updateUncommittedFiles(asNewAs: max(refs, changes.files ?? refs))
                    await branchStatus
                    await reloadIfRefsMoved()
                } else if let files = changes.files {
                    await updateUncommittedFiles(asNewAs: files)
                }
                lastDiskLook = (started, .now)
            }
            diskLook = nil
        }
    }

    private func lookAgain() {
        refsChecks += 1
        check?.cancel()
        check = Task { await checkForChanges() }
    }

    /// Checks out a badge's branch, unless a checkout is running already, and
    /// shows what that changed, with the branch's commit selected. For a remote
    /// branch, that may not be the commit that was clicked. When another
    /// worktree has the branch checked out, that's the one to look at, so it asks
    /// to show it instead, with the commit to select there. A remote's copy of the
    /// current branch has nothing to check out, so that goes to its commit instead.
    func checkOut(_ badge: CommitRowContent.Badge, showWorktree: @escaping (String, ObjectID?) -> Void) {
        guard let name = badge.refName else { return }
        checkOut(ref: name, showWorktree: showWorktree)
    }

    /// Checks out a branch by its full name, as its badge does. The refs panel's
    /// rows come here, since they have no badge.
    func checkOut(ref name: String, showWorktree: @escaping (String, ObjectID?) -> Void) {
        guard checkout == nil, branch.action == nil else { return }
        let commit = history?.refs.refs.first { $0.name == name }?.peeled
        if isRemoteCopyOfCurrentBranch(name) {
            if let commit { goTo(commit: commit) }
            return
        }
        let isDetached = history?.refs.currentBranch == nil
        checkout = Task {
            // Only a detached `HEAD` can leave commits behind this way, since a branch
            // keeps its own.
            if isDetached, let commit,
               let commitSwitch = try? await session.prepareToSwitch(to: commit, limit: DialogContent.listLimit, in: worktree),
               commitSwitch.asksFirst {
                pendingCommitSwitch = PendingCommitSwitch(
                    commitSwitch: commitSwitch,
                    commits: await branch.listed(commitSwitch.lost),
                    checkout: .init(branch: Ref.nameOnItsRemote(name) ?? Ref.shortName(name)) { [weak self] in
                        await self?.run(ref: name, showWorktree: showWorktree)
                    }
                )
            } else {
                await run(ref: name, showWorktree: showWorktree)
            }
            checkout = nil
        }
    }

    /// Runs the checkout of a branch and shows what that changed.
    private func run(ref name: String, showWorktree: @escaping (String, ObjectID?) -> Void) async {
        let title = Ref.shortName(name)
        await sayingIfSlow(title) {
            do {
                switch try await session.checkOut(ref: name, in: worktree) {
                case .checkedOut(_, let commit):
                    if let commit { select(commit: commit) }
                    lookAgain()
                    await reportBranchChange()
                case .inOtherWorktree(let folder, let commit):
                    showWorktree(folder, commit)
                }
            } catch {
                checkoutFailure = CheckoutFailure(branch: title, message: error.dialogMessage, command: error.gitArguments)
            }
        }
    }

    /// Whether a ref is what the current branch tracks, or another remote's branch
    /// of the same name.
    func isRemoteCopyOfCurrentBranch(_ name: String) -> Bool {
        guard let refs = history?.refs, let current = refs.currentBranch, name.hasPrefix(Ref.remoteBranchPrefix) else { return false }
        return name == refs.refs.first { $0.name == current }?.upstream || Ref.nameOnItsRemote(name) == Ref.shortName(current)
    }

    /// Goes to the commit of a row someone double-clicked away from its badges
    /// (decision 37). The commit `HEAD` is on, and the row for uncommitted changes,
    /// have nowhere to go. A row with another branch on it goes to that branch, as
    /// the branch's badge does.
    func goToRow(_ row: Int, showWorktree: @escaping (String, ObjectID?) -> Void) {
        guard let history, row >= rowOffset, row - rowOffset < history.rows.count else { return }
        let position = history.rows[row - rowOffset]
        guard position != history.head else { return }
        let other = badges[position]?.first { badge in
            badge.canCheckOut && !(badge.refName.map(isRemoteCopyOfCurrentBranch) ?? false)
        }
        if let other {
            checkOut(other, showWorktree: showWorktree)
        } else {
            goTo(commit: history.graph.id(at: position))
        }
    }

    /// Goes to a commit straight away when that loses nothing, and otherwise says
    /// what it would lose and asks. A worktree stuck partway through a merge or a
    /// rebase has to finish that first, which git would say anyway, but only after
    /// a question about commits that aren't really at risk.
    func goTo(commit id: ObjectID) {
        guard !branch.isBusy, branch.unfinished == nil, id != history?.refs.head else { return }
        checkout = Task {
            do {
                let commitSwitch = try await session.prepareToSwitch(to: id, limit: DialogContent.listLimit, in: worktree)
                if commitSwitch.asksFirst {
                    pendingCommitSwitch = PendingCommitSwitch(commitSwitch: commitSwitch, commits: await branch.listed(commitSwitch.lost))
                } else {
                    await run(commitSwitch)
                }
            } catch {
                branch.failure = BranchModel.Failure(title: "Can't go to \(id.hex.prefix(8))", error: error, changedNothing: true)
            }
            checkout = nil
        }
    }

    /// Goes to the commit that was asked about, whatever that loses.
    func confirmCommitSwitch() {
        guard let pending = pendingCommitSwitch, !branch.isBusy else { return }
        pendingCommitSwitch = nil
        checkout = Task {
            if let checkout = pending.checkout {
                await checkout.run()
            } else {
                await run(pending.commitSwitch)
            }
            checkout = nil
        }
    }

    /// Pushes the commits that were asked about, then goes to the commit.
    func pushThenConfirmCommitSwitch() {
        guard let pending = pendingCommitSwitch, !branch.isBusy else { return }
        pendingCommitSwitch = nil
        branch.push(thenGoingTo: pending.commitSwitch)
    }

    /// Moves the branch back to the commit that was asked about, and leaves everything
    /// since then staged.
    func keepChangesAndConfirmCommitSwitch() {
        guard let pending = pendingCommitSwitch, !branch.isBusy, let keeping = pending.commitSwitch.keepingChanges else { return }
        pendingCommitSwitch = nil
        checkout = Task {
            await run(keeping)
            checkout = nil
        }
    }

    // MARK: Reverting

    /// Whether something that moves `HEAD` can start now. git won't start one while
    /// the worktree is partway through something, and nothing runs alongside what's
    /// running.
    var canChangeHistory: Bool {
        !branch.isBusy && branch.unfinished == nil && checkout == nil && preparingRevert == nil && preparingAction == nil && branch.preparingIntegration == nil
    }

    /// Whether a commit can be reverted now.
    var canRevert: Bool { canChangeHistory }

    /// The commit of a row, or nil for the row for uncommitted changes.
    func commit(atRow row: Int) -> ObjectID? {
        guard let history, row >= rowOffset, row - rowOffset < history.rows.count else { return nil }
        return history.graph.id(at: history.rows[row - rowOffset])
    }

    /// Finds out what reverting a commit in this worktree would come to, and asks
    /// about it. It always asks, because that's where the choice is.
    func askToRevert(commit id: ObjectID) {
        guard canRevert else { return }
        preparingRevert = Task {
            do {
                pendingRevert = try await session.prepareToRevert(id, in: worktree)
            } catch {
                branch.failure = BranchModel.Failure(title: "Can't revert \(id.hex.prefix(8))", error: error, changedNothing: true)
            }
            preparingRevert = nil
        }
    }

    /// Reverts the commit that was asked about, the way someone chose. A revert that
    /// commits selects its commit. One that leaves its changes staged selects the
    /// row for them, where the commit box starts with git's message.
    func confirmRevert(_ way: CommitRevert.Way) {
        guard let revert = pendingRevert, !branch.isBusy, way == .leavingUncommitted || revert.canCommit else { return }
        pendingRevert = nil
        let short = String(revert.commit.hex.prefix(8))
        branch.run(.reverting, failure: "Can't revert \(short)", changesNothing: true) { [weak self, session, worktree] in
            switch try await session.revert(revert, way, in: worktree) {
            case .committed(let id):
                self?.selectNewCommit(id)
                return "Reverted \(short)"
            case .leftUncommitted:
                self?.selectChangesOnceTheyShow()
                self?.composer.askForFocus()
                return nil
            case .stoppedOnConflicts:
                let status = try? await session.status(in: worktree)
                self?.branch.conflict = BranchModel.Conflict(
                    work: .revert(commit: revert.commit),
                    files: status?.conflicted.map(\.path) ?? [],
                    ran: revert.arguments(way),
                    stagedBefore: way == .leavingUncommitted ? revert.stagedCount : 0
                )
                return nil
            }
        }
    }

    // MARK: Resetting, checking out and cherry-picking from a menu

    /// Finds out what moving the branch to a commit would come to, and asks how far
    /// to go. It always asks, because that's where the choice is (decision 33).
    func askToReset(to id: ObjectID, subject: String?) {
        guard canChangeHistory else { return }
        preparingAction = Task {
            do {
                let commitSwitch = try await session.prepareToReset(to: id, limit: DialogContent.listLimit, in: worktree)
                pendingReset = PendingReset(
                    commitSwitch: commitSwitch,
                    subject: subject,
                    commits: await branch.listed(commitSwitch.lost),
                    uncommittedFiles: uncommittedFiles
                )
            } catch {
                branch.failure = BranchModel.Failure(title: "Can't reset to \(id.hex.prefix(8))", error: error, changedNothing: true)
            }
            preparingAction = nil
        }
    }

    /// Moves the branch the way someone chose.
    func confirmReset() {
        guard let pending = pendingReset, !branch.isBusy else { return }
        pendingReset = nil
        checkout = Task {
            await run(pending.commitSwitch.resetting(pending.mode))
            checkout = nil
        }
    }

    /// Puts `HEAD` on a commit, away from any branch, which leaves every branch
    /// where it is.
    func checkOutDetached(commit id: ObjectID) {
        guard canChangeHistory, id != history?.refs.head else { return }
        checkout = Task {
            do {
                var commitSwitch = try await session.prepareToSwitch(to: id, limit: DialogContent.listLimit, in: worktree)
                commitSwitch.way = .detaching
                if commitSwitch.asksFirst, history?.refs.currentBranch == nil {
                    // Only a detached `HEAD` can leave commits behind this way.
                    pendingCommitSwitch = PendingCommitSwitch(commitSwitch: commitSwitch, commits: await branch.listed(commitSwitch.lost))
                } else {
                    commitSwitch.lostCount = 0
                    await run(commitSwitch)
                }
            } catch {
                branch.failure = BranchModel.Failure(title: "Can't check out \(id.hex.prefix(8))", error: error, changedNothing: true)
            }
            checkout = nil
        }
    }

    /// Finds out what's worth knowing before applying a commit. It goes straight away
    /// unless there's something to say, as with a merge.
    func askToCherryPick(commit id: ObjectID) {
        guard canChangeHistory else { return }
        preparingAction = Task {
            do {
                let pick = try await session.prepareToCherryPick(id, in: worktree)
                if pick.asksFirst {
                    pendingCherryPick = pick
                } else {
                    run(pick)
                }
            } catch {
                branch.failure = BranchModel.Failure(title: "Can't cherry-pick \(id.hex.prefix(8))", error: error, changedNothing: true)
            }
            preparingAction = nil
        }
    }

    /// Applies the commit that was asked about.
    func confirmCherryPick() {
        guard let pick = pendingCherryPick, !branch.isBusy else { return }
        pendingCherryPick = nil
        run(pick)
    }

    private func run(_ pick: CommitCherryPick) {
        branch.cherryPick(pick) { [weak self] in self?.selectNewCommit($0) }
    }

    // MARK: What the menus know

    /// Reads how every branch stands against `HEAD`, for the menus, which can't wait
    /// for git as they open.
    private func updateRefRelations(head: ObjectID?) {
        refRelationsUpdate?.cancel()
        guard let head else {
            refRelations = nil
            return
        }
        refRelationsUpdate = Task {
            async let remotes = session.remoteNames(in: worktree)
            guard let relations = try? await session.refRelations(to: head, in: worktree), !Task.isCancelled else { return }
            refRelations = (head, relations)
            remoteNames = (try? await remotes) ?? remoteNames
        }
    }

    /// Makes a branch push to and pull from one of the remotes.
    ///
    /// - Parameter ref: The branch's full name.
    func setUpstream(of ref: String, to remote: String) {
        guard let current = relation(of: ref), current.remote != remote else { return }
        let choice = UpstreamChoice(branch: Ref.shortName(ref), remote: remote, upstream: current.upstream) { relation(of: $0) != nil }
        branch.setUpstream(choice)
    }

    /// Asks about removing a remote, saying what goes with it.
    func askToRemove(remote: RemoteDetails) {
        let using = (refRelations?.relations ?? [:]).filter { name, relation in
            name.hasPrefix(Ref.branchPrefix) && (relation.upstream?.remote == remote.name || relation.pushRemote == remote.name)
        }
        branch.remoteRemoval = BranchModel.RemoteRemoval(
            name: remote.name,
            branchCount: remote.branches.count,
            branches: using.keys.map(Ref.shortName).sorted()
        )
    }

    /// How a branch stands against `HEAD`, unless `HEAD` has moved since that was read.
    func relation(of ref: String) -> RefRelation? {
        guard let refRelations, refRelations.head == history?.refs.head else { return nil }
        return refRelations.relations[ref]
    }

    /// Whether `HEAD` has a row's commit, when that doesn't take long to find out.
    func headContains(row: Int) -> Bool? {
        guard let history, let head = history.head, row >= rowOffset, row - rowOffset < history.rows.count else { return nil }
        return history.graph.reaches(history.rows[row - rowOffset], from: head, visitLimit: 20_000)
    }

    private func run(_ commitSwitch: CommitSwitch) async {
        await sayingIfSlow(commitSwitch.shortCommit) {
            do {
                let note = try await branch.go(commitSwitch)
                select(commit: commitSwitch.commit)
                if let note { branch.announce(note, undo: nil) }
                lookAgain()
                await reportBranchChange()
            } catch {
                branch.failure = BranchModel.Failure(title: commitSwitch.failureTitle, error: error, changedNothing: true)
            }
        }
    }

    /// Says in the title row what's being checked out, once that's taken long enough
    /// to mention.
    private func sayingIfSlow(_ name: String, while work: () async -> Void) async {
        let note = Task {
            guard (try? await Task.sleep(for: Self.slowCheckoutDelay)) != nil else { return }
            slowCheckout = name
        }
        await work()
        note.cancel()
        slowCheckout = nil
    }

    /// How long a checkout runs before the title row says so, so that a quick
    /// one doesn't flicker there.
    private static let slowCheckoutDelay = Duration.milliseconds(500)

    /// Updates the uncommitted files, and loads history again if a ref moved,
    /// such as after a commit. History has to change then too, because a row
    /// for uncommitted changes leads to `HEAD`.
    private func checkForChanges() async {
        async let branchStatus: Void = branch.refresh()
        await updateUncommittedFiles()
        await branchStatus
        await reloadIfRefsMoved()
    }

    /// Loads history again if any ref moved, or `HEAD` did.
    private func reloadIfRefsMoved() async {
        guard let history, let refs = try? await session.refs(in: worktree), !Task.isCancelled, refs != history.refs else { return }
        reload()
    }

    /// Reads the worktree's uncommitted files and what it's stuck partway through.
    ///
    /// - Parameter change: For a look because of a change on disk, the change's
    ///   number, which lets it share a `git status` with the sidebar. Nil runs
    ///   git afresh.
    private func updateUncommittedFiles(asNewAs change: Int? = nil) async {
        // A failure is usually a bare repository, which has no files to list.
        let status = if let change {
            try? await session.status(in: worktree, asNewAs: change)
        } else {
            try? await session.status(in: worktree)
        }
        let stopped = try? await session.stoppedWork(in: worktree)
        // The tooltip names the commit being reverted.
        var subject: String?
        if case .revert(let commit?) = stopped { subject = (try? await session.commits([commit]))?.first??.subject }
        if case .cherryPick(let commit?) = stopped { subject = (try? await session.commits([commit]))?.first??.subject }
        guard !Task.isCancelled else { return }
        show(uncommittedFiles: status?.fileCount ?? 0, staged: status?.staged.count ?? 0)
        show(unfinished: UnfinishedWork(work: stopped, conflicts: status?.conflicted.count ?? 0, subject: subject))
        composer.worktreeIsPartway(through: stopped)
        selectedChanges.refresh()
    }

    /// Says what the worktree is stuck partway through, which the row for
    /// uncommitted changes says too.
    private func show(unfinished: UnfinishedWork?) {
        reportConflicts(unfinished?.hasConflicts ?? false)
        guard unfinished != branch.unfinished else { return }
        branch.unfinished = unfinished
        historyVersion += 1
    }

    /// Adds or removes the row for uncommitted changes, which moves the rows
    /// below it.
    private func show(uncommittedFiles count: Int, staged: Int) {
        reportUncommittedFiles(count)
        guard count != uncommittedFiles || staged != stagedFiles else {
            selectChangesIfAsked()
            return
        }
        let hadRow = hasWorkingTreeRow
        uncommittedFiles = count
        stagedFiles = staged
        if hasWorkingTreeRow != hadRow {
            workingTreeLine = history.map { WorkingTreeLine(layout: $0.lanes, head: $0.head) }
            if selectedChanges.isSelected {
                selectRow(nil)
            } else if !selectedRows.isEmpty {
                selectedRows = IndexSet(selectedRows.map { $0 + (hasWorkingTreeRow ? 1 : -1) })
            }
        }
        historyVersion += 1
        selectChangesIfAsked()
    }

    private func selectChangesOnceTheyShow() {
        selectsChangesWhenTheyShow = true
        selectChangesIfAsked()
    }

    private func selectChangesIfAsked() {
        guard selectsChangesWhenTheyShow, hasWorkingTreeRow else { return }
        selectsChangesWhenTheyShow = false
        selectRow(0)
    }

    /// Selects a commit that history doesn't have yet, because Roga just made it,
    /// which the next load of history finds a row for.
    private func selectNewCommit(_ id: ObjectID) {
        selectedRows = []
        leaveSeveralCommits()
        selectedChanges.deselect()
        selectedCommit.show(id)
    }

    /// Loads history in the current order, unless it has loaded already. It
    /// returns once history is loaded, or when the task is cancelled.
    func load() async {
        let request = loadRequest
        guard request != loaded else { return }
        do {
            var firstSnapshot = true
            var isComplete = false
            for try await history in session.history(in: worktree, sort: request.sort) {
                if firstSnapshot {
                    firstSnapshot = false
                    graphGeneration += 1
                    texts = [:]
                    badges = Self.badges(history)
                    previewedCommits = []
                    reviewMain = Self.reviewMain(history.refs)
                    updateRefRelations(head: history.refs.head)
                }
                self.history = history
                if hasWorkingTreeRow { workingTreeLine = WorkingTreeLine(layout: history.lanes, head: history.head) }
                findSelectedRows(in: history)
                historyVersion += 1
                phase = .ready
                isComplete = history.isComplete
            }
            // The stream ends early when the task is cancelled.
            if isComplete { loaded = request }
        } catch is CancellationError {
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// Tints these commits in history, or none.
    private func preview(_ commits: [ObjectID]) {
        guard let history else { return }
        let positions = Set(commits.compactMap { history.graph.position(of: $0) })
        guard positions != previewedCommits else { return }
        previewedCommits = positions
        historyVersion += 1
    }

    /// The selected row, while only one is.
    var selectedRow: Int? {
        selectedRows.count == 1 ? selectedRows.first : nil
    }

    /// Whether the panels show what the selected rows are, rather than a branch
    /// or a stash, which select rows of their own or none.
    private var panelsFollowRows: Bool {
        switch selectedCommit.subject {
        case nil, .commit, .scattered: true
        case .comparison(let comparison):
            if case .branch = comparison.kind { false } else { true }
        case .stash: false
        }
    }

    /// Selects a row, or none.
    func selectRow(_ row: Int?) {
        let rows = row.map { IndexSet(integer: $0) } ?? IndexSet()
        guard rows != selectedRows || !panelsFollowRows else { return }
        selectedRows = rows
        leaveSeveralCommits()
        if hasWorkingTreeRow, row == 0 {
            selectedCommit.show(nil, keepingFile: true)
            selectedChanges.select()
            return
        }
        selectedChanges.deselect()
        guard let row, let history else {
            selectedCommit.show(nil)
            selectedFile.show(nil, in: nil)
            return
        }
        selectedCommit.show(history.graph.id(at: history.rows[row - rowOffset]))
    }

    /// Selects the rows someone picked in history. Several commits show as one
    /// diff when they're a run on one line, or compared when there are two
    /// (decision 56). The row for uncommitted changes isn't one of several.
    func selectRows(_ rows: IndexSet) {
        var rows = rows
        if hasWorkingTreeRow, rows.count > 1 { rows.remove(0) }
        guard rows.count > 1, let history else {
            selectRow(rows.first)
            return
        }
        guard rows != selectedRows || !panelsFollowRows else { return }
        selectedRows = rows
        leaveSeveralCommits()
        selectedChanges.deselect()
        let positions = rows.map { history.rows[$0 - rowOffset] }
        selectedCommits = positions.map { history.graph.id(at: $0) }
        selectedCommit.show(subject: Self.subject(of: positions, in: history.graph))
    }

    /// What several commits show as, from the newest, as history lists them, where
    /// a commit always comes before its parents. A run on one line, each the first
    /// parent of the one before, is one diff from the oldest one's parent. Two
    /// others are compared, from the older to the newer.
    static func subject(of positions: [CommitGraph.Position], in graph: CommitGraph) -> SelectedCommit.Subject {
        let isRun = zip(positions, positions.dropFirst()).allSatisfy { child, parent in
            (try? graph.parent(of: child, at: 0)) == parent
        }
        if isRun, let newest = positions.first, let oldest = positions.last {
            let base = try? graph.parent(of: oldest, at: 0)
            return .comparison(SelectedCommit.Comparison(
                kind: .run(count: positions.count, oldest: graph.id(at: oldest)),
                from: base.map { graph.id(at: $0) },
                to: graph.id(at: newest)
            ))
        }
        if positions.count == 2 {
            return .comparison(SelectedCommit.Comparison(kind: .pair, from: graph.id(at: positions[1]), to: graph.id(at: positions[0])))
        }
        return .scattered(positions.count)
    }

    /// Shows a comparison with the rows as they are, as when swapping two commits.
    func compare(_ comparison: SelectedCommit.Comparison) {
        selectedCommit.show(subject: .comparison(comparison))
    }

    /// Forgets the commits that were selected together, the review or stash that
    /// was showing, and the mark that went with them.
    private func leaveSeveralCommits() {
        selecting?.cancel()
        selecting = nil
        selectedCommits = []
        setMark(nil)
    }

    /// Marks a commit in history, or none.
    private func setMark(_ mark: (commit: ObjectID, title: String)?) {
        guard mark?.commit != self.mark?.commit || mark?.title != self.mark?.title else { return }
        self.mark = mark
        markedPosition = mark.flatMap { history?.graph.position(of: $0.commit) }
        historyVersion += 1
    }

    /// Selects a commit. While history hasn't reached it, which includes when
    /// history hasn't started loading, the commit is selected without a row until
    /// loading finds one. Once history is complete, it has to have the commit.
    func select(commit id: ObjectID) {
        if let row = history.flatMap({ Self.row(of: id, in: $0) }) {
            selectRow(row + rowOffset)
        } else if history?.isComplete != true {
            selectedRows = []
            leaveSeveralCommits()
            selectedChanges.deselect()
            selectedCommit.show(id)
        }
    }

    /// Shows what a stash holds in the panels, with no row selected and the commit
    /// it was made on marked in history (decision 56).
    func select(stash: StashDetails) {
        refs.select(ref: stash.name)
        guard selectedCommit.stash != stash else { return }
        selectedRows = []
        leaveSeveralCommits()
        selectedChanges.deselect()
        selectedCommit.show(subject: .stash(stash))
        selecting = Task {
            guard let base = (try? await session.commits([stash.commit]))?.first??.parents.first, !Task.isCancelled else { return }
            setMark((base, stash.name))
        }
    }

    /// The branches a branch is reviewed against: the main branch and its upstream,
    /// by their full names, and the main branch's short name. A branch that is the
    /// main branch, or its upstream, has nothing to review against.
    func reviewBase(for name: String) -> (refs: [String], title: String)? {
        guard let reviewMain, !reviewMain.refs.contains(name) else { return nil }
        return reviewMain
    }

    /// Works out what branches are reviewed against, once for each history,
    /// because every branch's row in the refs panel asks.
    private static func reviewMain(_ refs: RefList) -> (refs: [String], title: String)? {
        guard let main = refs.mainBranch else { return nil }
        let upstream = main.upstream.flatMap { upstream in refs.refs.contains { $0.name == upstream } ? upstream : nil }
        return ([main.name] + [upstream].compactMap(\.self), main.shortName)
    }

    /// Selects a branch's commits since it left the main branch, marks where it
    /// left, and shows them as one diff (decision 56).
    func review(branch name: String) {
        guard let base = reviewBase(for: name) else { return }
        refs.select(ref: name)
        leaveSeveralCommits()
        selecting = Task {
            do {
                let review = try await session.review(branch: name, against: base.refs)
                try Task.checkCancellation()
                show(review, against: base.refs[0])
            } catch is CancellationError {
            } catch {
                branch.failure = BranchModel.Failure(title: "Can't review \(Ref.shortName(name))", error: error, changedNothing: true)
            }
        }
    }

    /// Whether there's a history to replay yet.
    var canReplayHistory: Bool { history?.head != nil }

    /// Opens a window that replays a branch's history (decision 62), or with
    /// no name, whatever the worktree is on.
    ///
    /// - Parameter name: The branch's full name, such as `refs/heads/main`.
    func replayHistory(ofBranch name: String? = nil) {
        guard let history, let head = history.head else { return }
        let ref = name.flatMap { name in history.refs.refs.first { $0.name == name } }
        guard let tip = ref.map({ history.graph.position(of: $0.peeled) }) ?? head else { return }
        let title = name.map(Ref.shortName) ?? history.refs.currentBranch.map(Ref.shortName) ?? "HEAD"
        ReplayWindows.show(ReplayModel(
            session: session,
            graph: history.graph,
            tip: tip,
            branchName: title,
            tags: Self.replayTags(history)
        ))
    }

    /// The newest tags, for replaying everything since one of them.
    private static func replayTags(_ history: History) -> [ReplayModel.Tag] {
        let tags = history.refs.refs.filter { $0.kind == .tag }.compactMap { ref in
            history.graph.position(of: ref.peeled).map { ReplayModel.Tag(name: Ref.shortName(ref.name), commit: $0) }
        }
        return Array(tags.sorted { history.graph.commitTime(at: $0.commit) > history.graph.commitTime(at: $1.commit) }.prefix(20))
    }

    /// Reviews the branch the worktree is on, from the menu bar.
    func reviewCurrentBranch() {
        guard let current = history?.refs.currentBranch else { return }
        review(branch: current)
    }

    /// The short name of the branch that the branch the worktree is on would be
    /// reviewed against, or nil when it can't be.
    var currentReviewBase: String? {
        history?.refs.currentBranch.flatMap(reviewBase(for:))?.title
    }

    /// Selects a review's commits and shows them as one diff.
    private func show(_ review: BranchReview, against main: String) {
        selectedChanges.deselect()
        selectedCommits = review.commits
        selectedRows = history.map { rows(of: review.commits, in: $0) } ?? []
        selectedCommit.show(subject: .comparison(SelectedCommit.Comparison(
            kind: .branch(name: review.branch, against: main, count: review.commits.count, hasMore: review.hasMore),
            from: review.base,
            to: review.tip
        )))
        setMark(review.base.map { ($0, "merge base") })
    }

    /// The branch whose review is showing, by its full name.
    var reviewedBranch: String? {
        guard case .branch(let name, _, _, _) = selectedCommit.comparison?.kind else { return nil }
        return name
    }

    /// Reviews the branch again once history has loaded, because what moved may
    /// have been the branch, as when an agent commits. A branch that's gone leaves
    /// nothing selected.
    private func refreshReview() {
        guard let name = reviewedBranch, case .comparison(let shown) = selectedCommit.subject else { return }
        guard let base = reviewBase(for: name), history?.refs.refs.contains(where: { $0.name == name }) == true else {
            selectRow(nil)
            return
        }
        selecting?.cancel()
        selecting = Task {
            guard let review = try? await session.review(branch: name, against: base.refs), !Task.isCancelled else { return }
            guard review.tip != shown.to || review.base != shown.from || review.commits.count != selectedCommits.count else { return }
            show(review, against: base.refs[0])
        }
    }

    /// The rows of some commits in history, going through history once.
    private func rows(of commits: [ObjectID], in history: History) -> IndexSet {
        let positions = Set(commits.compactMap { history.graph.position(of: $0) })
        guard !positions.isEmpty else { return [] }
        var rows = IndexSet()
        for (row, position) in history.rows.enumerated() where positions.contains(position) {
            rows.insert(row + rowOffset)
        }
        return rows
    }

    /// Selects the commit a ref points to, and the ref's row in the refs panel.
    func select(ref name: String, commit id: ObjectID) {
        refs.select(ref: name)
        select(commit: id)
    }

    /// Whether history has a commit. A shallow clone doesn't have the parents
    /// of its oldest commits, for example.
    func hasCommit(_ id: ObjectID) -> Bool {
        history?.graph.position(of: id) != nil
    }

    /// Finds the selected commits in a history that has just loaded, where they
    /// can be in other rows, and the marked one. Once history is complete, a
    /// commit that isn't in it is gone, such as after deleting its branch. A
    /// review is read again then, because the branch may have moved.
    private func findSelectedRows(in history: History) {
        markedPosition = mark.flatMap { history.graph.position(of: $0.commit) }
        if !selectedCommits.isEmpty {
            selectedRows = rows(of: selectedCommits, in: history)
            if history.isComplete, reviewedBranch != nil { refreshReview() }
            return
        }
        guard let id = selectedCommit.id else { return }
        selectedRows = Self.row(of: id, in: history).map { IndexSet(integer: $0 + rowOffset) } ?? []
        if selectedRows.isEmpty, history.isComplete { selectedCommit.show(nil) }
    }

    /// Goes through the rows, which takes up to a millisecond for as many as
    /// Linux has, so it's only for when history loads or a commit is selected
    /// by its ID.
    private static func row(of id: ObjectID, in history: History) -> Int? {
        history.graph.position(of: id).flatMap { history.rows.firstIndex(of: $0) }
    }

    var hasWorkingTreeRow: Bool { uncommittedFiles > 0 }

    /// How many rows come before the first commit.
    private var rowOffset: Int { hasWorkingTreeRow ? 1 : 0 }

    var rowCount: Int { (history?.rows.count ?? 0) + rowOffset }

    /// What a row shows, with whatever text has loaded.
    func rowContent(_ row: Int) -> CommitRowContent {
        if hasWorkingTreeRow, row == 0 {
            var files = uncommittedFiles == 1 ? "1 uncommitted file" : "\(uncommittedFiles.formatted()) uncommitted files"
            if stagedFiles > 0 { files += ", \(stagedFiles.formatted()) staged" }
            let unfinished = branch.unfinished
            let isWarning = unfinished?.hasConflicts == true
            return CommitRowContent(
                shortID: "",
                subject: isWarning ? unfinished?.title : [unfinished?.verb, files].compactMap(\.self).joined(separator: " · "),
                body: isWarning ? "· \(files)" : nil,
                lanes: workingTreeLine?.row,
                isWorkingTree: true,
                isWarning: isWarning
            )
        }
        let row = row - rowOffset
        guard let history, row >= 0, row < history.rows.count else { return CommitRowContent(shortID: "") }
        let position = history.rows[row]
        let text = texts[position]
        var badges = badges[position] ?? []
        if position == markedPosition, let mark { badges.append(CommitRowContent.Badge(title: mark.title, kind: .mark)) }
        return CommitRowContent(
            shortID: String(history.graph.id(at: position).hex.prefix(8)),
            badges: badges,
            subject: text?.subject,
            body: text?.body,
            author: text?.author,
            date: text?.date,
            lanes: hasWorkingTreeRow
                ? workingTreeLine?.adding(to: history.lanes.row(row), at: row)
                : history.lanes.row(row),
            isPreviewed: previewedCommits.contains(position)
        )
    }

    /// Asks which of the branches on a commit should go. The commit is the one history
    /// shows them on, which is what someone was looking at when they asked.
    ///
    /// - Parameter names: The full names of all the branches on the commit.
    func askToDeleteBranches(_ names: [String]) {
        guard let commit = history?.refs.refs.first(where: { names.contains($0.name) })?.peeled else { return }
        branch.askToDelete(branches: names, on: commit)
    }

    /// Reads the text of the rows that don't have it yet, and returns the
    /// rows that got it.
    func loadText(for rows: Range<Int>) async -> IndexSet {
        guard let history else { return [] }
        let generation = graphGeneration
        let offset = rowOffset
        let rows = (rows.lowerBound - offset..<rows.upperBound - offset).clamped(to: 0..<history.rows.count)
        let wanted = rows.filter { texts[history.rows[$0]] == nil }
        guard !wanted.isEmpty else { return [] }

        let commits: [CommitInfo?]
        do {
            commits = try await session.commits(wanted.map { history.graph.id(at: history.rows[$0]) })
        } catch {
            return []
        }
        let messages = await Self.subjectsAndBodies(of: commits)
        guard generation == graphGeneration else { return [] }

        if texts.count + wanted.count > Self.textLimit {
            // Keep only the rows around the ones being shown.
            let keep = Set(rows.map { history.rows[$0] })
            texts = texts.filter { keep.contains($0.key) }
        }
        for (index, row) in wanted.enumerated() {
            texts[history.rows[row]] = commits[index].map { commit in
                RowText(subject: messages[index].subject, body: messages[index].body, author: commit.author.name, date: Self.format(commit.author.time, now: now))
            } ?? RowText(subject: "This commit is missing from the repository.", body: "", author: "", date: "")
        }
        return IndexSet(wanted.map { $0 + offset })
    }

    /// Reads the subject and the body line of each commit, away from the main
    /// thread, because going through the messages of a screen's commits takes
    /// a few milliseconds on a repository like Linux.
    @concurrent private static func subjectsAndBodies(of commits: [CommitInfo?]) async -> [(subject: String, body: String)] {
        commits.map { commit in commit.map { ($0.subject, $0.bodyLine) } ?? ("", "") }
    }

    private static func badges(_ history: History) -> [CommitGraph.Position: [CommitRowContent.Badge]] {
        var badges = history.refsByCommit.mapValues { Self.badges(for: $0, currentBranch: history.refs.currentBranch) }
        if history.refs.currentBranch == nil, let head = history.head {
            badges[head, default: []].insert(CommitRowContent.Badge(title: "HEAD", kind: .detachedHead), at: 0)
        }
        return badges
    }

    /// The badges for the refs on one commit. A branch and its upstream share a
    /// badge when they have the same name, because they're the same thing here,
    /// and every other remote's branch of that name joins them. Without its
    /// upstream on the commit, a branch has no cloud to add to, so a remote's
    /// branch keeps its own badge.
    static func badges(for refs: [Ref], currentBranch: String?) -> [CommitRowContent.Badge] {
        var upstreams: Set<String> = []
        if refs.contains(where: { $0.upstream != nil }) {
            let names = Set(refs.map(\.name))
            upstreams = Set(refs.compactMap(\.upstreamOfSameName)).intersection(names)
        }
        // Other remotes' branches, by what the branch that shares a badge is called.
        var others: [String: [String]] = [:]
        if !upstreams.isEmpty {
            let sharing = Set(upstreams.compactMap(Ref.nameOnItsRemote))
            for ref in refs where !upstreams.contains(ref.name) {
                if let name = Ref.nameOnItsRemote(ref.name), sharing.contains(name) {
                    others[name, default: []].append(ref.name)
                }
            }
        }
        let onBadges = Set(others.values.joined()).union(upstreams)
        return refs.compactMap { ref in
            guard !onBadges.contains(ref.name) else { return nil }
            let kind: CommitRowContent.Badge.Kind = switch ref.kind {
            case .branch: ref.name == currentBranch ? .currentBranch : .branch
            case .remoteBranch: .remoteBranch
            case .tag, .other: .tag
            }
            let upstream = ref.upstreamOfSameName.flatMap { upstreams.contains($0) ? $0 : nil }
            return CommitRowContent.Badge(
                title: ref.shortName,
                kind: kind,
                refName: ref.name,
                upstream: upstream,
                otherRemoteBranches: upstream == nil ? [] : others[ref.shortName] ?? []
            )
        }
    }

    /// Shows the day and time for dates this year, and the day and year for
    /// older ones.
    private static func format(_ time: Int64, now: Date) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(time))
        if Calendar.current.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
