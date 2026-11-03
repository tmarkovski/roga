import Foundation
import GitCore

/// Which repositories a window's sidebar lists, which the rail picks
/// (decision 16).
enum SidebarScope: Codable, Hashable, Sendable {
    case all
    /// An organization, by its name in lowercase.
    case organization(String)
    /// The repositories that aren't in an organization.
    case other
}

/// Where a window's sidebar is, which SwiftUI saves with the window.
struct SidebarPlace: Codable, Hashable, Sendable {
    var scope = SidebarScope.all
    /// The worktree the window showed last in each organization.
    var lastSelections: [SidebarScope: WorktreeSelection] = [:]

    /// What the rail shows as selected, which is All while the rail is hidden
    /// or when the organization it was on has gone.
    func effectiveScope(in groups: RepositoryGroups, showsRail: Bool) -> SidebarScope {
        showsRail && groups.scopes.contains(scope) ? scope : .all
    }

    /// Remembers that the window shows `selection`, and moves the sidebar to
    /// where it's listed, as when File > Open adds a repository to another
    /// organization.
    mutating func record(_ selection: WorktreeSelection, in groups: RepositoryGroups) {
        guard let repository = groups.repository(at: selection.repository) else { return }
        let owner = groups.scope(of: repository)
        lastSelections[owner] = selection
        if scope != .all { scope = owner }
    }
}

/// The repositories with one owner, when there are at least two of them.
struct RepositoryOrganization: Identifiable {
    /// The owner's name in lowercase, because hosts don't care about case.
    let id: String
    /// The owner's name as one of its URLs spells it.
    let name: String
    /// From A to Z.
    let repositories: [ListedRepository]

    var scope: SidebarScope { .organization(id) }
    var monogram: String { Self.monogram(name) }

    /// Two letters for the rail: the first letters of the name's first two
    /// words, or else its first two letters.
    static func monogram(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        let letters = words.count >= 2 ? [words[0].prefix(1), words[1].prefix(1)] : [(words.first ?? name[...]).prefix(2)]
        return letters.joined().uppercased()
    }
}

/// The repositories grouped the way the rail picks them (decision 16).
struct RepositoryGroups {
    /// From A to Z.
    private(set) var organizations: [RepositoryOrganization] = []
    /// The repositories of owners with only one, from A to Z by owner.
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
        for (id, owned) in Dictionary(grouping: sorted.filter { $0.owner != nil }, by: { $0.owner!.lowercased() }) {
            if owned.count >= 2 {
                organizations.append(RepositoryOrganization(id: id, name: owned[0].owner!, repositories: owned))
            } else {
                otherOwners += owned
            }
        }
        organizations.sort { $0.id < $1.id }
        otherOwners.sort { $0.nameWithOwner.localizedStandardCompare($1.nameWithOwner) == .orderedAscending }
        noRemote = sorted.filter { $0.owner == nil }
    }

    /// What the rail lists, from the top.
    var scopes: [SidebarScope] {
        [.all] + organizations.map(\.scope) + (hasOthers ? [.other] : [])
    }

    var hasOthers: Bool { !otherOwners.isEmpty || !noRemote.isEmpty }

    /// What the menus call a scope.
    func title(of scope: SidebarScope) -> String {
        switch scope {
        case .all: "All Repositories"
        case .organization(let id): organizations.first { $0.id == id }?.name ?? id
        case .other: "Other"
        }
    }

    func repositories(in scope: SidebarScope) -> [ListedRepository] {
        switch scope {
        case .all: all
        case .organization(let id): organizations.first { $0.id == id }?.repositories ?? []
        case .other: otherOwners + noRemote
        }
    }

    func repository(at path: String) -> ListedRepository? {
        all.first { $0.path == path }
    }

    /// The organization a repository is in, or Other.
    func scope(of repository: ListedRepository) -> SidebarScope {
        scope(ofOwner: repository.owner)
    }

    /// Where a repository with this owner would be listed, as for one that
    /// could be added.
    func scope(ofOwner owner: String?) -> SidebarScope {
        guard let id = owner?.lowercased(), organizations.contains(where: { $0.id == id }) else { return .other }
        return .organization(id)
    }
}

/// One row of the sidebar's list.
enum SidebarItem: Identifiable {
    case label(String)
    /// A repository's row, which is its main worktree. `detail` is what follows
    /// its name in gray.
    case repository(ListedRepository, title: String, detail: String?)
    /// `isLast` means nothing follows it under its repository, so the line down
    /// from the repository's row ends here.
    case worktree(ListedRepository, Worktree, isLast: Bool)
    /// The row that stands for the worktrees a collapsed repository hides, with
    /// how many uncommitted files they have. Clicking it shows them.
    case hiddenWorktrees(ListedRepository, title: String, uncommittedFiles: Int)

    var id: String {
        switch self {
        case .label(let title): "label \(title)"
        case .repository(let repository, _, _): "repository \(repository.path)"
        case .worktree(_, let worktree, _): "worktree \(worktree.path)"
        case .hiddenWorktrees(let repository, _, _): "hidden worktrees \(repository.path)"
        }
    }
}

/// Works out the rows that the sidebar's list shows (docs/main-window.md).
struct SidebarLayout {
    let groups: RepositoryGroups
    let scope: SidebarScope
    let selection: WorktreeSelection?
    let place: SidebarPlace

    var items: [SidebarItem] {
        var items: [SidebarItem] = []
        switch scope {
        case .all, .organization:
            for repository in groups.repositories(in: scope) { append(repository, to: &items) }
        case .other:
            if !groups.otherOwners.isEmpty { items.append(.label("Other owners")) }
            for repository in groups.otherOwners { append(repository, title: repository.nameWithOwner, to: &items) }
            if !groups.noRemote.isEmpty { items.append(.label("No remote")) }
            for repository in groups.noRemote { append(repository, to: &items) }
        }
        return items
    }

    /// A collapsed repository shows only its selected worktree, and a row for
    /// the rest.
    private func append(_ repository: ListedRepository, title: String? = nil, to items: inout [SidebarItem]) {
        items.append(.repository(repository, title: title ?? repository.name, detail: detail(of: repository)))
        let linked = repository.worktrees.filter { !$0.isMain }
        let shown = repository.isExpanded ? linked : linked.filter { isSelected($0, in: repository) }
        let hidden = repository.isExpanded ? [] : linked.filter { !isSelected($0, in: repository) }
        for worktree in shown {
            items.append(.worktree(repository, worktree, isLast: hidden.isEmpty && worktree.path == shown.last?.path))
        }
        guard !hidden.isEmpty else { return }
        let noun = hidden.count == 1 ? "worktree" : "worktrees"
        items.append(.hiddenWorktrees(
            repository,
            title: shown.isEmpty ? "\(hidden.count) \(noun)" : "\(hidden.count) more \(noun)",
            uncommittedFiles: hidden.reduce(0) { $0 + repository.uncommittedFiles[$1.path, default: 0] }
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
