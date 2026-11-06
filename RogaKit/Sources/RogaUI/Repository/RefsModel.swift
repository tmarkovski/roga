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
    /// Whether the filter field shows, which it doesn't until someone asks for it.
    private(set) var isFilterShown = false

    @ObservationIgnored private let session: RepositorySession
    @ObservationIgnored private let worktree: String
    /// The latest sorted lists, because sorting all of Linux's tags on every
    /// key press in the filter would be wasted work.
    @ObservationIgnored private var sorted: (sort: Sort, details: RefDetails)?
    /// The latest rows of the branches, in folders, because a remote can have
    /// thousands of branches, and the panel asks for them on every step of the
    /// arrow keys.
    @ObservationIgnored private var grouped: (sort: Sort, filter: String, collapsed: Set<String>, rows: BranchRows)?

    init(session: RepositorySession, worktree: String) {
        self.session = session
        self.worktree = worktree
    }

    /// Shows the filter field, or goes back to it if it's showing.
    func showFilter() {
        isFilterShown = true
        wantsFilterFocus = true
    }

    /// Hides the filter field, and lists everything again.
    func closeFilter() {
        filter = ""
        isFilterShown = false
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
        grouped = nil
    }

    /// What the panel lists, in `sort` order, with what `filter` leaves.
    func shown(sort: Sort) -> RefDetails? {
        guard case .loaded(let details) = content else { return nil }
        if sorted?.sort != sort { sorted = (sort, Self.sorted(details, by: sort)) }
        return sorted.map { Self.filtered($0.details, by: filter) }
    }

    /// The rows of the branches that `shown(sort:)` lists, in folders. While
    /// the filter has text, every folder that has a match in it is open, and
    /// shows only its matches.
    ///
    /// - Parameter collapsed: The closed folders, by what the full names of
    ///   their branches start with, as in `refs/heads/tm/`.
    func branchRows(sort: Sort, collapsed: Set<String>) -> BranchRows? {
        if let grouped, grouped.sort == sort, grouped.filter == filter, grouped.collapsed == collapsed {
            return grouped.rows
        }
        guard let details = shown(sort: sort) else { return nil }
        let rows = Self.branchRows(details, sort: sort, collapsed: filter.isEmpty ? collapsed : [])
        grouped = (sort, filter, collapsed, rows)
        return rows
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
        result.branches.sort { first, second in
            if (first.name == details.currentBranch) != (second.name == details.currentBranch) {
                return first.name == details.currentBranch
            }
            return comesFirst((first.shortName, first.date), (second.shortName, second.date), by: sort)
        }
        for index in result.remotes.indices {
            result.remotes[index].branches.sort { comesFirst(($0.shortName, $0.date), ($1.shortName, $1.date), by: sort) }
        }
        result.tags.sort { comesFirst(($0.shortName, $0.date), ($1.shortName, $1.date), by: sort, descendingNames: true) }
        return result
    }

    /// Whether one ref comes before another. By date, the latest comes first
    /// and one with no date comes last, and refs of the same date go by name.
    /// Numbers in names count as numbers, and case doesn't count.
    private static func comesFirst(
        _ first: (name: String, date: Int64?),
        _ second: (name: String, date: Int64?),
        by sort: Sort,
        descendingNames: Bool = false
    ) -> Bool {
        if sort == .date, first.date != second.date {
            return (first.date ?? .min) > (second.date ?? .min)
        }
        let order = first.name.compare(second.name, options: [.numeric, .caseInsensitive])
        return descendingNames ? order == .orderedDescending : order == .orderedAscending
    }

    /// The rows of the panel's local branches and of each remote's, in folders.
    static func branchRows(_ details: RefDetails, sort: Sort, collapsed: Set<String>) -> BranchRows {
        BranchRows(
            local: rows(of: details.branches, under: Ref.branchPrefix, current: details.currentBranch, sort: sort, collapsed: collapsed),
            remotes: Dictionary(
                details.remotes.map { remote in
                    let prefix = Ref.remoteBranchPrefix + remote.name + "/"
                    return (remote.name, rows(of: remote.branches, under: prefix, current: nil, sort: sort, collapsed: collapsed))
                },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    /// The rows of a list of branches, with each part of a name before a slash
    /// as a folder (decision 50). `tm/fix-login` is `fix-login` in the folder
    /// `tm`, and `a/b/c` is `c` in `b` in `a`. A folder shows even with one
    /// branch in it, so that a branch stays where it is when another one with
    /// its prefix comes along.
    ///
    /// The current branch comes first among the rows beside it, in its folder
    /// or at the top. By name, folders come next, then the other branches,
    /// each from A to Z. By date, folders and branches go from the latest to
    /// the oldest together, a folder at the date of the latest branch under it.
    ///
    /// - Parameters:
    ///   - prefix: What every full name in the list starts with ahead of its
    ///     folders, such as `refs/heads/` or `refs/remotes/origin/`.
    ///   - current: The full name of the current branch, if it's in the list.
    ///   - collapsed: The closed folders, by what the full names of their
    ///     branches start with, as in `refs/heads/tm/`. What's in them has no
    ///     rows.
    static func rows<Branch: ListedBranch>(
        of branches: [Branch],
        under prefix: String,
        current: String?,
        sort: Sort,
        collapsed: Set<String>
    ) -> [BranchRow<Branch>] {
        let top = BranchFolder<Branch>()
        for branch in branches {
            let parts = branch.shortName.split(separator: "/")
            var folder = top
            for part in parts.dropLast() {
                folder = folder.folder(named: String(part))
                folder.count += 1
                if let date = branch.date { folder.latest = max(folder.latest ?? date, date) }
            }
            folder.branches.append((branch, parts.last.map(String.init) ?? branch.shortName))
        }
        var rows: [BranchRow<Branch>] = []
        top.append(to: &rows, ref: prefix, depth: 0, current: current, sort: sort, collapsed: collapsed)
        return rows
    }

    /// A folder of a list of branches, with what's in it.
    private final class BranchFolder<Branch: ListedBranch> {
        var folders: [String: BranchFolder] = [:]
        var branches: [(branch: Branch, title: String)] = []
        /// How many branches are under it, in it or in its folders.
        var count = 0
        /// The date of the latest branch under it.
        var latest: Int64?

        func folder(named name: String) -> BranchFolder {
            if let folder = folders[name] { return folder }
            let folder = BranchFolder()
            folders[name] = folder
            return folder
        }

        private enum Item {
            case folder(name: String, BranchFolder)
            case branch(Branch, title: String)
        }

        /// Adds the rows of what's in it, and of what's in its open folders.
        func append(to rows: inout [BranchRow<Branch>], ref: String, depth: Int, current: String?, sort: Sort, collapsed: Set<String>) {
            var items = folders.map { Item.folder(name: $0.key, $0.value) } + branches.map { Item.branch($0.branch, title: $0.title) }
            func isCurrent(_ item: Item) -> Bool {
                if case .branch(let branch, _) = item { branch.name == current } else { false }
            }
            func isFolder(_ item: Item) -> Bool {
                if case .folder = item { true } else { false }
            }
            func key(_ item: Item) -> (name: String, date: Int64?) {
                switch item {
                case .folder(let name, let folder): (name, folder.latest)
                case .branch(let branch, let title): (title, branch.date)
                }
            }
            items.sort { first, second in
                if isCurrent(first) != isCurrent(second) { return isCurrent(first) }
                if sort == .name, isFolder(first) != isFolder(second) { return isFolder(first) }
                return RefsModel.comesFirst(key(first), key(second), by: sort)
            }
            for item in items {
                switch item {
                case .folder(let name, let folder):
                    let folderRef = ref + name + "/"
                    let isCollapsed = collapsed.contains(folderRef)
                    rows.append(BranchRow(content: .folder(ref: folderRef, name: name, count: folder.count, isCollapsed: isCollapsed), depth: depth))
                    if !isCollapsed {
                        folder.append(to: &rows, ref: folderRef, depth: depth + 1, current: current, sort: sort, collapsed: collapsed)
                    }
                case .branch(let branch, let title):
                    rows.append(BranchRow(content: .branch(branch, title: title), depth: depth))
                }
            }
        }
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

/// A branch the panel lists, local or on a remote.
protocol ListedBranch {
    /// The full name, such as `refs/heads/tm/fix-login`.
    var name: String { get }
    /// The name in its list, such as `tm/fix-login`, whose parts before a
    /// slash are the folders it's in.
    var shortName: String { get }
    /// When its tip was committed, in seconds since 1970.
    var date: Int64? { get }
}

extension BranchDetails: ListedBranch {}
extension RemoteBranchDetails: ListedBranch {}

/// A row of a list of branches in folders: a folder, or a branch in the
/// folders above it.
struct BranchRow<Branch: ListedBranch>: Identifiable {
    enum Content {
        /// A folder, by what the full names of the branches in it start with,
        /// as in `refs/heads/tm/`, with its own name, how many branches are
        /// under it, and whether it's closed.
        case folder(ref: String, name: String, count: Int, isCollapsed: Bool)
        /// A branch, with what's left of its name after its folders.
        case branch(Branch, title: String)
    }

    let content: Content
    /// How many folders it's in.
    let depth: Int

    /// A folder's ends with a slash, which a branch's name can't, so they
    /// never clash.
    var id: String {
        switch content {
        case .folder(let ref, _, _, _): ref
        case .branch(let branch, _): branch.name
        }
    }

    var branch: Branch? {
        if case .branch(let branch, _) = content { branch } else { nil }
    }
}

/// The rows of the panel's branches, in folders.
struct BranchRows {
    var local: [BranchRow<BranchDetails>]
    /// Each remote's, by the remote's name.
    var remotes: [String: [BranchRow<RemoteBranchDetails>]]
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
