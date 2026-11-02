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
    /// files to be slow enough to mention. git lists about 100,000 a second.
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

    /// The request whose history has loaded completely.
    @ObservationIgnored private var loaded: LoadRequest?
    /// The text of commits the list has drawn, by position. Positions belong
    /// to one loaded graph, so the text goes when another graph arrives.
    @ObservationIgnored private var texts: [CommitGraph.Position: RowText] = [:]
    @ObservationIgnored private var graphGeneration = 0
    @ObservationIgnored private var badges: [CommitGraph.Position: [CommitRowContent.Badge]] = [:]
    @ObservationIgnored private let now = Date()
    @ObservationIgnored private let defaults: UserDefaults
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

    init(session: RepositorySession, worktree: String, defaults: UserDefaults = .standard) {
        self.session = session
        self.worktree = worktree
        self.defaults = defaults
    }

    var loadRequest: LoadRequest { LoadRequest(sort: sort, reloads: reloads) }

    /// The name of the current branch, or a short ID for a detached `HEAD`.
    var headDescription: String? {
        guard let history else { return nil }
        if let branch = history.refs.currentBranch { return Ref.shortName(branch) }
        guard let head = history.refs.head else { return nil }
        return "detached at " + head.hex.prefix(8)
    }

    func reload() {
        reloads += 1
    }

    /// Writes what the repository's commit-graph files are missing, in the
    /// background, unless the user turned that off. History on screen stays
    /// as it is, because the files would only change how quickly it loads.
    func updateCommitGraph() {
        guard defaults.keepsCommitGraphCurrent else {
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

    /// Loads history in the current order, unless it has loaded already. It
    /// returns once history is loaded, or when the task is cancelled, as it
    /// is when the order changes or the window shows another worktree.
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

    var rowCount: Int { history?.rows.count ?? 0 }

    /// What a row shows, with whatever text has loaded.
    func rowContent(_ row: Int) -> CommitRowContent {
        guard let history, row < history.rows.count else { return CommitRowContent(shortID: "") }
        let position = history.rows[row]
        let text = texts[position]
        return CommitRowContent(
            shortID: String(history.graph.id(at: position).hex.prefix(8)),
            badges: badges[position] ?? [],
            subject: text?.subject,
            author: text?.author,
            date: text?.date,
            lanes: history.lanes.row(row)
        )
    }

    /// Reads the text of the rows that don't have it yet, and returns the
    /// rows that got it.
    func loadText(for rows: Range<Int>) async -> IndexSet {
        guard let history else { return [] }
        let generation = graphGeneration
        let rows = rows.clamped(to: 0..<history.rows.count)
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
        return IndexSet(wanted)
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
