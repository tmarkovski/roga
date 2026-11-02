import Foundation
import GitCore
import Observation
import RepositoryEngine

/// What the refs panel shows of a worktree's repository. The lists on screen
/// stay until the new ones arrive, so reading them again doesn't flicker.
@Observable
final class RefsModel {
    enum Content: Equatable {
        case loading
        case loaded(RefDetails)
        /// git couldn't list them. The message says why.
        case failed(String)
    }

    /// How the panel orders its lists.
    enum Sort: String, CaseIterable {
        case name
        case date

        var title: String {
            switch self {
            case .name: "Name"
            case .date: "Date"
            }
        }
    }

    /// The panel's sections, in the order it shows them.
    enum Section: String, CaseIterable {
        case branches
        case remotes
        case tags
        case stashes

        var title: String {
            switch self {
            case .branches: "Branches"
            case .remotes: "Remotes"
            case .tags: "Tags"
            case .stashes: "Stashes"
            }
        }
    }

    private(set) var content = Content.loading
    /// The text that narrows every section at once.
    var filter = ""
    /// The full name of the ref whose row the user selected. It only shows as
    /// selected while history has that ref's commit selected.
    private(set) var selectedRef: String?
    /// Goes up when the user moves through the rows with the keyboard, so that
    /// the list knows to scroll to the selected one.
    private(set) var selectionSteps = 0
    /// Whether a menu command asked for the keyboard to go to the filter, which
    /// the panel does once it's showing.
    var wantsFilterFocus = false

    @ObservationIgnored private let session: RepositorySession
    @ObservationIgnored private let worktree: String
    /// The latest sorted lists, because sorting all of Linux's tags on every
    /// key press in the filter would be wasted work.
    @ObservationIgnored private var sorted: (sort: Sort, details: RefDetails)?

    init(session: RepositorySession, worktree: String) {
        self.session = session
        self.worktree = worktree
    }

    /// Reads the lists again. It returns when that's done, or when the task is
    /// cancelled.
    func load() async {
        do {
            let details = try await session.refDetails(in: worktree)
            guard !Task.isCancelled else { return }
            show(.loaded(details))
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            show(.failed(String(describing: error)))
        }
    }

    private func show(_ new: Content) {
        guard new != content else { return }
        content = new
        sorted = nil
    }

    /// What the panel lists, in `sort` order, with what `filter` leaves.
    func shown(sort: Sort) -> RefDetails? {
        guard case .loaded(let details) = content else { return nil }
        if sorted?.sort != sort { sorted = (sort, Self.sorted(details, by: sort)) }
        return sorted.map { Self.filtered($0.details, by: filter) }
    }

    /// Selects a ref's row.
    func select(ref name: String) {
        selectedRef = name
    }

    /// Records that the keyboard moved the selection to a ref's row.
    func step(to name: String) {
        selectedRef = name
        selectionSteps += 1
    }

    /// Orders the lists. The current branch comes first, where it's easy to
    /// find. By name, tags go from the latest version to the oldest, because
    /// the ones someone looks for are the recent ones. By date, everything goes
    /// from the latest to the oldest. Stashes stay in the order git gives them,
    /// which is already that.
    static func sorted(_ details: RefDetails, by sort: Sort) -> RefDetails {
        var result = details
        func comesFirst(_ first: (name: String, date: Int64?), _ second: (name: String, date: Int64?), descendingNames: Bool = false) -> Bool {
            if sort == .date, first.date != second.date {
                return (first.date ?? .min) > (second.date ?? .min)
            }
            let order = first.name.compare(second.name, options: [.numeric, .caseInsensitive])
            return descendingNames ? order == .orderedDescending : order == .orderedAscending
        }
        result.branches.sort { first, second in
            if (first.name == details.currentBranch) != (second.name == details.currentBranch) {
                return first.name == details.currentBranch
            }
            return comesFirst((first.shortName, first.date), (second.shortName, second.date))
        }
        for index in result.remotes.indices {
            result.remotes[index].branches.sort { comesFirst(($0.shortName, $0.date), ($1.shortName, $1.date)) }
        }
        result.tags.sort { comesFirst(($0.shortName, $0.date), ($1.shortName, $1.date), descendingNames: true) }
        return result
    }

    /// Keeps what matches `filter`, ignoring case: branches and tags by name,
    /// and stashes by message. A remote stays with all its branches when its
    /// own name matches, and otherwise with the branches that match.
    static func filtered(_ details: RefDetails, by filter: String) -> RefDetails {
        guard !filter.isEmpty else { return details }
        func matches(_ text: String) -> Bool { text.range(of: filter, options: .caseInsensitive) != nil }
        var result = details
        result.branches.removeAll { !matches($0.shortName) }
        result.remotes = details.remotes.compactMap { remote in
            if matches(remote.name) { return remote }
            var kept = remote
            kept.branches.removeAll { !matches($0.shortName) }
            return kept.branches.isEmpty ? nil : kept
        }
        result.tags.removeAll { !matches($0.shortName) }
        result.stashes.removeAll { !matches($0.message) }
        return result
    }
}

extension BranchDetails {
    /// The second line of a branch's row: where it's checked out and how far
    /// it is from the branch it's compared with, or else when it last changed.
    func subtitle(isCurrent: Bool, now: Date = Date()) -> String {
        var parts: [String] = []
        if !isCurrent, let worktree { parts.append("in " + (worktree as NSString).lastPathComponent) }
        if let comparison { parts.append(comparison.summary) }
        if parts.isEmpty, let date { parts.append(RefDates.relative(date, now: now)) }
        return parts.joined(separator: " · ")
    }
}

extension BranchComparison {
    /// As in `3 ahead, 2 behind main`.
    var summary: String {
        switch (ahead, behind) {
        case (0, 0): "up to date with \(other)"
        case (_, 0): "\(ahead.formatted()) ahead of \(other)"
        case (0, _): "\(behind.formatted()) behind \(other)"
        default: "\(ahead.formatted()) ahead, \(behind.formatted()) behind \(other)"
        }
    }
}

extension StashDetails {
    /// The second line of a stash's row: what git calls it, and how long ago
    /// it was made.
    func subtitle(now: Date = Date()) -> String {
        ([name] + (date.map { [RefDates.relative($0, now: now)] } ?? [])).joined(separator: " · ")
    }
}

/// How the panel shows dates, which come in seconds since 1970.
enum RefDates {
    private static let relativeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// As in `2 hours ago`.
    static func relative(_ time: Int64, now: Date = Date()) -> String {
        relativeFormatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(time)), relativeTo: now)
    }

    /// As in `1 Jan`, with the year for an older date.
    static func short(_ time: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(time))
        if Calendar.current.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
