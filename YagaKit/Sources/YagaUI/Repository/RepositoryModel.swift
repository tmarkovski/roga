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
    /// Goes up when the refs panel should read its lists again, if it's showing.
    private(set) var refsChecks = 0
    /// How many files have uncommitted changes. While there are any, a row for
    /// them comes before the first commit.
    private(set) var uncommittedFiles = 0
    /// The selected row. It's nil while the history being loaded hasn't reached
    /// the selected commit yet, and the commit stays selected.
    private(set) var selectedRow: Int?

    /// The request whose history has loaded completely.
    @ObservationIgnored private var loaded: LoadRequest?
    /// The text of commits the list has drawn, by position. Positions belong
    /// to one loaded graph, so the text goes when another graph arrives.
    @ObservationIgnored private var texts: [CommitGraph.Position: RowText] = [:]
    @ObservationIgnored private var graphGeneration = 0
    @ObservationIgnored private var badges: [CommitGraph.Position: [CommitRowContent.Badge]] = [:]
    @ObservationIgnored private let now = Date()
    /// Whether the user wants commit-graph files kept up to date.
    @ObservationIgnored private let keepsCommitGraphCurrent: () -> Bool
    /// Says how many files are uncommitted, whenever that's been checked.
    @ObservationIgnored private let reportUncommittedFiles: (Int) -> Void
    /// The line from the row for uncommitted changes down to `HEAD`.
    @ObservationIgnored private var workingTreeLine: WorkingTreeLine?
    /// The check that yaga becoming active started, which a newer one replaces.
    @ObservationIgnored private(set) var check: Task<Void, Never>?
    /// The running update of the commit-graph files, which isn't tied to any
    /// view, so that it carries on when the window shows another worktree.
    @ObservationIgnored private(set) var commitGraphUpdate: Task<Void, Never>?

    private struct RowText {
        var subject: String
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
        reportUncommittedFiles: @escaping (Int) -> Void = { _ in }
    ) {
        self.session = session
        self.worktree = worktree
        self.keepsCommitGraphCurrent = keepsCommitGraphCurrent
        self.reportUncommittedFiles = reportUncommittedFiles
        selectedCommit = SelectedCommit(session: session)
        selectedChanges = SelectedChanges(session: session, worktree: worktree, selectedFile: selectedCommit.selectedFile)
        refs = RefsModel(session: session, worktree: worktree)
        selectedChanges.onLoad = { [weak self] count in self?.show(uncommittedFiles: count) }
    }

    /// The file selected in whichever panel is showing, which the diff panel
    /// shows.
    var selectedFile: SelectedFile { selectedCommit.selectedFile }

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
        guard loadRequest != loaded else { return await checkForChanges() }
        async let status: Void = updateUncommittedFiles()
        await load()
        await status
    }

    /// Looks at the worktree again, because yaga became active and whatever
    /// the user was doing elsewhere may have changed it.
    func becameActive() {
        refsChecks += 1
        check?.cancel()
        check = Task { await checkForChanges() }
    }

    /// Updates the uncommitted files, and loads history again if a ref moved,
    /// such as after a commit. History has to change then too, because a row
    /// for uncommitted changes leads to `HEAD`.
    private func checkForChanges() async {
        await updateUncommittedFiles()
        guard let history, let refs = try? await session.refs(in: worktree), !Task.isCancelled, refs != history.refs else { return }
        reload()
    }

    private func updateUncommittedFiles() async {
        // A failure is usually a bare repository, which has no files to list.
        let status = try? await session.status(in: worktree)
        guard !Task.isCancelled else { return }
        show(uncommittedFiles: status?.fileCount ?? 0)
        selectedChanges.refresh()
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

    /// Selects a commit, if history has it.
    func select(commit id: ObjectID) {
        if let row = history.flatMap({ Self.row(of: id, in: $0) }) { selectRow(row + rowOffset) }
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
            return CommitRowContent(
                shortID: "",
                subject: uncommittedFiles == 1 ? "1 uncommitted file" : "\(uncommittedFiles.formatted()) uncommitted files",
                lanes: workingTreeLine?.row,
                isWorkingTree: true
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
            author: text?.author,
            date: text?.date,
            lanes: hasWorkingTreeRow
                ? workingTreeLine?.adding(to: history.lanes.row(row), at: row)
                : history.lanes.row(row)
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
        guard generation == graphGeneration else { return [] }

        if texts.count + wanted.count > Self.textLimit {
            // Keep only the rows around the ones being shown.
            let keep = Set(rows.map { history.rows[$0] })
            texts = texts.filter { keep.contains($0.key) }
        }
        for (row, commit) in zip(wanted, commits) {
            texts[history.rows[row]] = commit.map { commit in
                RowText(subject: commit.subject, author: commit.author.name, date: Self.format(commit.author.time, now: now))
            } ?? RowText(subject: "This commit is missing from the repository.", author: "", date: "")
        }
        return IndexSet(wanted.map { $0 + offset })
    }

    private static func badges(_ history: History) -> [CommitGraph.Position: [CommitRowContent.Badge]] {
        var badges = history.refsByCommit.mapValues { refs in
            refs.map { ref -> CommitRowContent.Badge in
                let kind: CommitRowContent.Badge.Kind = switch ref.kind {
                case .branch: ref.name == history.refs.currentBranch ? .currentBranch : .branch
                case .remoteBranch: .remoteBranch
                case .tag, .other: .tag
                }
                return CommitRowContent.Badge(title: ref.shortName, kind: kind)
            }
        }
        if history.refs.currentBranch == nil, let head = history.head {
            badges[head, default: []].insert(CommitRowContent.Badge(title: "HEAD", kind: .detachedHead), at: 0)
        }
        return badges
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
