import CommitGraph
import Foundation
import GitCore
import GitRunner
import HistoryUI
import Observation
import RepositoryEngine

/// Connects one repository's session to the views that show it.
@Observable
final class RepositoryModel {
    enum Phase {
        case opening
        case ready
        case failed(String)
    }

    let path: String
    private(set) var phase = Phase.opening
    private(set) var location: RepositoryLocation?
    private(set) var history: History?
    /// Goes up each time `history` changes, so the commit list knows to show
    /// the new rows.
    private(set) var historyVersion = 0
    var sort = HistoryOrder.Sort.topological
    /// Goes up when the user asks to load history again.
    private(set) var reloads = 0

    @ObservationIgnored private var session: RepositorySession?
    /// The text of commits the list has drawn, by position. Positions belong
    /// to one loaded graph, so the text goes when another graph arrives.
    @ObservationIgnored private var texts: [CommitGraph.Position: RowText] = [:]
    @ObservationIgnored private var graphGeneration = 0
    @ObservationIgnored private var badges: [CommitGraph.Position: [CommitRowContent.Badge]] = [:]
    @ObservationIgnored private let now = Date()

    private struct RowText {
        var subject: String
        var author: String
        var date: String
    }

    /// The most commits whose text is kept. Text for others is read again
    /// when they scroll back into view, which takes about a millisecond for
    /// a screen.
    private static let textLimit = 20_000

    init(path: String) {
        self.path = path
    }

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

    /// Opens the repository if it isn't open yet, and loads its history in
    /// the current order. It returns once history is loaded, or when the task
    /// is cancelled, as it is when the order changes.
    func load(git: Git) async {
        do {
            let session: RepositorySession
            if let open = self.session {
                session = open
            } else {
                session = try await RepositorySession.open(containing: path, git: git)
                self.session = session
                location = session.location
            }
            var firstSnapshot = true
            for try await history in session.history(sort: sort) {
                if firstSnapshot {
                    firstSnapshot = false
                    graphGeneration += 1
                    texts = [:]
                    badges = Self.badges(history)
                }
                self.history = history
                historyVersion += 1
                phase = .ready
            }
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
        guard let history, let session else { return [] }
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
