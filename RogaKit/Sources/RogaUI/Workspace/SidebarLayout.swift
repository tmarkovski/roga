import Foundation
import GitCore

/// A group of repositories in the sidebar's list, under a gray label
/// (decision 53).
enum SidebarGroup: Hashable, Sendable {
    /// An organization, by its name in lowercase.
    case organization(String)
    /// The repositories that aren't in an organization.
    case other

    /// What the setting that keeps collapsed groups saves for it, with one
    /// group to a line. An owner's name can't have a line break, and the prefix
    /// keeps an organization called "other" apart from Other.
    var key: String {
        switch self {
        case .organization(let id): "organization " + id
        case .other: "other"
        }
    }

    init?(key: some StringProtocol) {
        if key == "other" {
            self = .other
        } else if key.hasPrefix("organization ") {
            self = .organization(String(key.dropFirst("organization ".count)))
        } else {
            return nil
        }
    }
}

/// What order the sidebar lists repositories in, within each group or in the
/// whole list.
enum SidebarSort: String, CaseIterable, Sendable {
    /// From A to Z.
    case name
    /// The repositories whose worktrees have the most uncommitted files first,
    /// and from A to Z among those with as many.
    case changes

    var title: String {
        switch self {
        case .name: "Name"
        case .changes: "Uncommitted changes"
        }
    }
}

/// How the sidebar arranges its repositories, which the menu at the top of its
/// list picks, for every window (decision 53).
struct SidebarArrangement: Equatable {
    /// Whether the list has a group for each organization, and one for the
    /// rest, or every repository in one run.
    var groupsByOrganization = true
    var sort = SidebarSort.name
    /// The groups showing only their label.
    var collapsed: Set<SidebarGroup> = []

    /// The collapsed groups, from what the setting saves.
    static func collapsed(from saved: String) -> Set<SidebarGroup> {
        Set(saved.split(separator: "\n").compactMap(SidebarGroup.init(key:)))
    }

    /// What the setting saves for these collapsed groups.
    static func saved(_ collapsed: Set<SidebarGroup>) -> String {
        collapsed.map(\.key).sorted().joined(separator: "\n")
    }
}

/// The names of the settings that the sidebar and the menu bar share.
enum SidebarSettings {
    static let groupsByOrganization = "sidebarGroupsByOrganization"
    static let sort = "sidebarSort"
    static let collapsedGroups = "sidebarCollapsedGroups"
}

/// The repositories with one owner, when there are at least two of them.
struct RepositoryOrganization: Identifiable {
    /// The owner's name in lowercase, because hosts don't care about case.
    let id: String
    /// The owner's name as one of its URLs spells it.
    let name: String
    /// From A to Z.
    let repositories: [ListedRepository]

    var group: SidebarGroup { .organization(id) }
}

/// The repositories grouped by organization (decisions 16, 18 and 53).
struct RepositoryGroups {
    /// From A to Z.
    private(set) var organizations: [RepositoryOrganization] = []
    /// The repositories whose owners have no others, from A to Z by owner.
    private(set) var otherOwners: [ListedRepository] = []
    /// From A to Z.
    private(set) var noRemote: [ListedRepository] = []
    let all: [ListedRepository]
    /// The names that more than one repository has.
    let repeatedNames: Set<String>

    init(_ repositories: [ListedRepository]) {
        let sorted = repositories.sorted { first, second in
            switch first.name.localizedStandardCompare(second.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: first.path < second.path
            }
        }
        all = sorted
        repeatedNames = Set(Dictionary(grouping: sorted, by: \.name).filter { $0.value.count > 1 }.keys)
        var owned: [String: (name: String, repositories: [ListedRepository])] = [:]
        for repository in sorted {
            for owner in repository.owners {
                owned[owner.lowercased(), default: (owner, [])].repositories.append(repository)
            }
        }
        for (id, group) in owned where group.repositories.count >= 2 {
            organizations.append(RepositoryOrganization(id: id, name: group.name, repositories: group.repositories))
        }
        organizations.sort { $0.id < $1.id }
        let grouped = Set(organizations.map(\.id))
        otherOwners = sorted.filter { repository in
            !repository.owners.isEmpty && grouped.isDisjoint(with: repository.owners.map { $0.lowercased() })
        }
        otherOwners.sort { $0.nameWithOwner.localizedStandardCompare($1.nameWithOwner) == .orderedAscending }
        noRemote = sorted.filter(\.owners.isEmpty)
    }

    /// The groups, from the top: each organization from A to Z, then Other
    /// when it has any repositories.
    var groups: [SidebarGroup] {
        organizations.map(\.group) + (otherOwners.isEmpty && noRemote.isEmpty ? [] : [.other])
    }

    /// What a group's label says.
    func title(of group: SidebarGroup) -> String {
        switch group {
        case .organization(let id): organizations.first { $0.id == id }?.name ?? id
        case .other: "Other"
        }
    }

    /// Every repository with that owner, including ones listed under another
    /// of their organizations.
    func repositories(in group: SidebarGroup) -> [ListedRepository] {
        switch group {
        case .organization(let id): organizations.first { $0.id == id }?.repositories ?? []
        case .other: otherOwners + noRemote
        }
    }
}

/// One row of the sidebar's list.
enum SidebarItem: Identifiable {
    /// A group's label. `hiddenWorktrees` are the folders of the worktrees it
    /// hides while it's collapsed, whose agents its mark stands for.
    case group(SidebarGroup, title: String, isCollapsed: Bool, hiddenWorktrees: [String])
    /// A repository's row, which is its main worktree. `detail` is what follows
    /// its name in gray.
    case repository(ListedRepository, title: String, detail: String?)
    /// `isLast` means nothing follows it under its repository, so the line down
    /// from the repository's row ends here.
    case worktree(ListedRepository, Worktree, isLast: Bool)
    /// The row that stands for the worktrees a collapsed repository hides, with
    /// their folders and how many uncommitted files they have. Clicking it
    /// shows them.
    case hiddenWorktrees(ListedRepository, title: String, worktrees: [String], uncommittedFiles: Int, hasConflicts: Bool)

    var id: String {
        switch self {
        case .group(let group, _, _, _): "group \(group.key)"
        case .repository(let repository, _, _): "repository \(repository.path)"
        case .worktree(_, let worktree, _): "worktree \(worktree.path)"
        case .hiddenWorktrees(let repository, _, _, _, _): "hidden worktrees \(repository.path)"
        }
    }

    /// The folders of the worktrees whose agents the row's mark stands for
    /// (decision 41). A repository's row is its main worktree, and the row for
    /// hidden worktrees marks the most urgent of the ones it hides, as its
    /// count adds up their files, so that an agent waiting in one shows
    /// without expanding the repository. A collapsed group's label does the
    /// same for every worktree it hides.
    var markedWorktrees: [String] {
        switch self {
        case .group(_, _, _, let worktrees): worktrees
        case .repository(let repository, _, _): repository.worktrees.first.map { [$0.path] } ?? []
        case .worktree(_, let worktree, _): [worktree.path]
        case .hiddenWorktrees(_, _, let worktrees, _, _): worktrees
        }
    }
}

/// Works out the rows that the sidebar's list shows (docs/main-window.md).
struct SidebarLayout {
    let groups: RepositoryGroups
    let arrangement: SidebarArrangement
    let selection: WorktreeSelection?

    var items: [SidebarItem] {
        var items: [SidebarItem] = []
        guard arrangement.groupsByOrganization else {
            for repository in sorted(groups.all) { append(repository, to: &items) }
            return items
        }
        // A repository with remotes in two organizations is listed once, under
        // the first of its owners that has a group, which is `origin`'s when
        // that one does.
        let organizations = Set(groups.organizations.map(\.id))
        func listedGroup(of repository: ListedRepository) -> SidebarGroup {
            repository.owners.lazy.map { $0.lowercased() }.first(where: organizations.contains).map(SidebarGroup.organization) ?? .other
        }
        for group in groups.groups {
            let repositories = groups.repositories(in: group).filter { listedGroup(of: $0) == group }
            guard !repositories.isEmpty else { continue }
            let isCollapsed = arrangement.collapsed.contains(group)
            // A collapsed group goes on showing the repository that has the
            // selected worktree, as a collapsed repository does.
            let shown = isCollapsed ? repositories.filter(hasSelection) : repositories
            let hidden = isCollapsed ? repositories.filter { !hasSelection($0) } : []
            items.append(.group(group, title: groups.title(of: group), isCollapsed: isCollapsed, hiddenWorktrees: hidden.flatMap { $0.worktrees.map(\.path) }))
            for repository in sorted(shown) {
                append(repository, title: group == .other ? repository.nameWithOwner : repository.name, to: &items)
            }
        }
        return items
    }

    /// The repositories in the order `arrangement` picks, from ones that are
    /// in order by name.
    private func sorted(_ repositories: [ListedRepository]) -> [ListedRepository] {
        switch arrangement.sort {
        case .name:
            return repositories
        case .changes:
            // By the number first, and then by where each was, which keeps
            // repositories with as many in order by name.
            let files: [Int] = repositories.map { $0.uncommittedFiles.values.reduce(0, +) }
            let order: [Int] = repositories.indices.sorted { first, second in
                files[first] != files[second] ? files[first] > files[second] : first < second
            }
            return order.map { repositories[$0] }
        }
    }

    private func hasSelection(_ repository: ListedRepository) -> Bool {
        selection?.repository == repository.path
    }

    /// A collapsed repository shows only its selected worktree and the ones it's
    /// keeping, and a row for the rest.
    private func append(_ repository: ListedRepository, title: String? = nil, to items: inout [SidebarItem]) {
        items.append(.repository(repository, title: title ?? repository.name, detail: detail(of: repository)))
        let linked = repository.worktrees.filter { !$0.isMain }
        func isShown(_ worktree: Worktree) -> Bool {
            repository.isExpanded || repository.keptWorktrees.contains(worktree.path) || isSelected(worktree, in: repository)
        }
        let shown = linked.filter(isShown)
        let hidden = linked.filter { !isShown($0) }
        for worktree in shown {
            items.append(.worktree(repository, worktree, isLast: hidden.isEmpty && worktree.path == shown.last?.path))
        }
        guard !hidden.isEmpty else { return }
        let noun = hidden.count == 1 ? "worktree" : "worktrees"
        items.append(.hiddenWorktrees(
            repository,
            title: shown.isEmpty ? "\(hidden.count) \(noun)" : "\(hidden.count) more \(noun)",
            worktrees: hidden.map(\.path),
            uncommittedFiles: hidden.reduce(0) { $0 + repository.uncommittedFiles[$1.path, default: 0] },
            hasConflicts: hidden.contains { repository.conflictedWorktrees.contains($0.path) }
        ))
    }

    /// The folder it's in when another repository has the same name, or else
    /// the main worktree's branch unless it's the usual one.
    private func detail(of repository: ListedRepository) -> String? {
        if groups.repeatedNames.contains(repository.name) {
            return (repository.parentFolder as NSString).abbreviatingWithTildeInPath
        }
        guard let main = repository.worktrees.first, !main.isBare, !["main", "master"].contains(main.title) else { return nil }
        return main.title
    }

    private func isSelected(_ worktree: Worktree, in repository: ListedRepository) -> Bool {
        selection == WorktreeSelection(repository: repository.path, worktree: worktree.path)
    }
}
