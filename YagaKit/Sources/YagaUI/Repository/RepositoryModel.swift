import CommitGraph
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
    /// Goes up when the refs panel should read its lists again, if it's showing.
    private(set) var refsChecks = 0
    /// How many files have uncommitted changes. While there are any, a row for
    /// them comes before the first commit.
    private(set) var uncommittedFiles = 0
    /// The selected row. It's nil while the history being loaded hasn't reached
    /// the selected commit yet, and the commit stays selected.
    private(set) var selectedRow: Int?
    /// The branch being checked out, once that's taken long enough to mention.
    private(set) var slowCheckout: String?
    /// What to tell the user about a checkout that didn't work, until they've
    /// seen it.
    var checkoutFailure: CheckoutFailure?

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
    @ObservationIgnored private let now = Date()
    /// Whether the user wants commit-graph files kept up to date.
    @ObservationIgnored private let keepsCommitGraphCurrent: () -> Bool
    /// Says how many files are uncommitted, whenever that's been checked.
    @ObservationIgnored private let reportUncommittedFiles: (Int) -> Void
    /// Says whether the worktree has conflicts, whenever that's been checked.
    @ObservationIgnored private let reportConflicts: (Bool) -> Void
    /// Says that the worktree is on another branch, or the repository has a new
    /// worktree, because of something yaga did, and returns once the sidebar knows.
    @ObservationIgnored private let reportBranchChange: () async -> Void
    /// The line from the row for uncommitted changes down to `HEAD`.
    @ObservationIgnored private var workingTreeLine: WorkingTreeLine?
    /// The check that yaga becoming active started, which a newer one replaces.
    @ObservationIgnored private(set) var check: Task<Void, Never>?
    /// The running update of the commit-graph files, which isn't tied to any
    /// view, so that it carries on when the window shows another worktree.
    @ObservationIgnored private(set) var commitGraphUpdate: Task<Void, Never>?
    /// The running checkout. It isn't tied to any view either, because cancelling
    /// it would stop git while it may be writing the worktree's files.
    @ObservationIgnored private(set) var checkout: Task<Void, Never>?

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
        fetchesByItself: @escaping () -> Bool = { UserDefaults.standard.fetchesByItself }
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
        selectedChanges.onLoad = { [weak self] count in self?.show(uncommittedFiles: count) }
        branch.isCheckingOut = { [weak self] in self?.checkout != nil }
        branch.lookAgain = { [weak self] in self?.lookAgain() }
        branch.showChanges = { [weak self] in
            guard let self, hasWorkingTreeRow else { return }
            selectRow(0)
        }
        branch.showPreview = { [weak self] commits in self?.preview(commits) }
    }

    /// The file selected in whichever panel is showing, which the diff panel
    /// shows.
    var selectedFile: SelectedFile { selectedCommit.selectedFile }

    /// What whichever panel is showing lists of its files.
    var fileList: FileListModel { selectedCommit.fileList }

    /// Whether a panel has files to list, or will have once they're read.
    var canFilterFiles: Bool { selectedChanges.isSelected || selectedCommit.id != nil }

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
    /// yaga is doing about it, or nil when there's nothing to say.
    var slowHistoryExplanation: String? {
        let slow = "History loads slowly without a commit-graph file"
        switch commitGraphState {
        case .unknown, .finished(.upToDate), .finished(.written):
            return nil
        case .updating:
            return slow + ". yaga is writing one in the background, so this repository opens faster next time."
        case .turnedOff:
            return slow + ". To have yaga write one, turn on Keep commit-graph files up to date in Settings."
        case .finished(.skipped(let reason)):
            return slow + ", and yaga doesn't write one here. " + reason.description
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

    /// Looks at the worktree again, because yaga became active and whatever
    /// the user was doing elsewhere may have changed it.
    func becameActive() {
        lookAgain()
        branch.fetchByItself()
    }

    /// Looks at the worktree again, because something yaga did elsewhere, such as
    /// deleting another worktree and its branch from the sidebar, moved its refs.
    func refsChanged() {
        lookAgain()
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
    /// to show it instead, with the commit to select there.
    func checkOut(_ badge: CommitRowContent.Badge, showWorktree: @escaping (String, ObjectID?) -> Void) {
        guard checkout == nil, branch.action == nil, let name = badge.refName else { return }
        checkout = Task {
            let note = Task {
                guard (try? await Task.sleep(for: Self.slowCheckoutDelay)) != nil else { return }
                slowCheckout = badge.title
            }
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
                checkoutFailure = CheckoutFailure(branch: badge.title, message: (error as? GitError)?.message ?? String(describing: error))
            }
            note.cancel()
            slowCheckout = nil
            checkout = nil
        }
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
        guard let history, let refs = try? await session.refs(in: worktree), !Task.isCancelled, refs != history.refs else { return }
        reload()
    }

    private func updateUncommittedFiles() async {
        // A failure is usually a bare repository, which has no files to list.
        let status = try? await session.status(in: worktree)
        let stopped = try? await session.stoppedWork(in: worktree)
        guard !Task.isCancelled else { return }
        show(uncommittedFiles: status?.fileCount ?? 0)
        show(unfinished: UnfinishedWork(work: stopped, conflicts: status?.conflicted.count ?? 0))
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
    private func show(uncommittedFiles count: Int) {
        reportUncommittedFiles(count)
        guard count != uncommittedFiles else { return }
        let hadRow = hasWorkingTreeRow
        uncommittedFiles = count
        if hasWorkingTreeRow != hadRow {
            workingTreeLine = history.map { WorkingTreeLine(layout: $0.lanes, head: $0.head) }
            if selectedChanges.isSelected {
                selectRow(nil)
            } else if let row = selectedRow {
                selectedRow = row + (hasWorkingTreeRow ? 1 : -1)
            }
        }
        historyVersion += 1
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
                }
                self.history = history
                if hasWorkingTreeRow { workingTreeLine = WorkingTreeLine(layout: history.lanes, head: history.head) }
                findSelectedRow(in: history)
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

    /// Selects a row, or none.
    func selectRow(_ row: Int?) {
        guard row != selectedRow else { return }
        selectedRow = row
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

    /// Selects a commit. While history hasn't reached it, which includes when
    /// history hasn't started loading, the commit is selected without a row until
    /// loading finds one. Once history is complete, it has to have the commit.
    func select(commit id: ObjectID) {
        if let row = history.flatMap({ Self.row(of: id, in: $0) }) {
            selectRow(row + rowOffset)
        } else if history?.isComplete != true {
            selectedRow = nil
            selectedChanges.deselect()
            selectedCommit.show(id)
        }
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

    /// Finds the selected commit in a history that has just loaded, where it
    /// can be in another row. Once history is complete, a commit that isn't in
    /// it is gone, such as after deleting its branch.
    private func findSelectedRow(in history: History) {
        guard let id = selectedCommit.id else { return }
        selectedRow = Self.row(of: id, in: history).map { $0 + rowOffset }
        if selectedRow == nil, history.isComplete { selectedCommit.show(nil) }
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
            let files = uncommittedFiles == 1 ? "1 uncommitted file" : "\(uncommittedFiles.formatted()) uncommitted files"
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
        return CommitRowContent(
            shortID: String(history.graph.id(at: position).hex.prefix(8)),
            badges: badges[position] ?? [],
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
    /// badge when they have the same name, because they're the same thing here.
    /// Any other remote's branch keeps its own.
    static func badges(for refs: [Ref], currentBranch: String?) -> [CommitRowContent.Badge] {
        var upstreams: Set<String> = []
        if refs.contains(where: { $0.upstream != nil }) {
            let names = Set(refs.map(\.name))
            upstreams = Set(refs.compactMap(\.upstreamOfSameName)).intersection(names)
        }
        return refs.compactMap { ref in
            guard !upstreams.contains(ref.name) else { return nil }
            let kind: CommitRowContent.Badge.Kind = switch ref.kind {
            case .branch: ref.name == currentBranch ? .currentBranch : .branch
            case .remoteBranch: .remoteBranch
            case .tag, .other: .tag
            }
            let upstream = ref.upstreamOfSameName.flatMap { upstreams.contains($0) ? $0 : nil }
            return CommitRowContent.Badge(title: ref.shortName, kind: kind, refName: ref.name, upstream: upstream)
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
