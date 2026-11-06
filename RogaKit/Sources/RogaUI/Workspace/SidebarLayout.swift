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
    /// organization. A repository in several organizations leaves the sidebar
    /// on the one it's on, and doesn't change what the others showed last.
    mutating func record(_ selection: WorktreeSelection, in groups: RepositoryGroups) {
        guard let repository = groups.repository(at: selection.repository) else { return }
        let listedIn = groups.scopes(of: repository)
        if scope != .all, !listedIn.contains(scope) { scope = listedIn[0] }
        for place in scope == .all ? listedIn : [scope] {
            lastSelections[place] = selection
        }
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
        let onTheRail = Set(organizations.map(\.id))
        otherOwners = sorted.filter { repository in
            !repository.owners.isEmpty && onTheRail.isDisjoint(with: repository.owners.map { $0.lowercased() })
        }
        otherOwners.sort { $0.nameWithOwner.localizedStandardCompare($1.nameWithOwner) == .orderedAscending }
        noRemote = sorted.filter(\.owners.isEmpty)
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

    /// The organizations a repository is in, or else Other.
    func scopes(of repository: ListedRepository) -> [SidebarScope] {
        scopes(ofOwners: repository.owners)
    }

    /// Where a repository with these owners would be listed, as for one that
    /// could be added.
    func scopes(ofOwners owners: [String]) -> [SidebarScope] {
        let onTheRail = owners.map { $0.lowercased() }.filter { id in organizations.contains { $0.id == id } }
        return onTheRail.isEmpty ? [.other] : onTheRail.map(SidebarScope.organization)
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
    /// their folders and how many uncommitted files they have. Clicking it
    /// shows them.
    case hiddenWorktrees(ListedRepository, title: String, worktrees: [String], uncommittedFiles: Int, hasConflicts: Bool)

    var id: String {
        switch self {
        case .label(let title): "label \(title)"
        case .repository(let repository, _, _): "repository \(repository.path)"
        case .worktree(_, let worktree, _): "worktree \(worktree.path)"
        case .hiddenWorktrees(let repository, _, _, _, _): "hidden worktrees \(repository.path)"
        }
    }

    /// The folders of the worktrees whose agents the row's mark stands for
    /// (decision 41). A repository's row is its main worktree, and the row for
    /// hidden worktrees marks the most urgent of the ones it hides, as its
    /// count adds up their files, so that an agent waiting in one shows
    /// without expanding the repository.
    var markedWorktrees: [String] {
        switch self {
        case .label: []
        case .repository(let repository, _, _): repository.worktrees.first.map { [$0.path] } ?? []
        case .worktree(_, let worktree, _): [worktree.path]
        case .hiddenWorktrees(_, _, let worktrees, _, _): worktrees
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
