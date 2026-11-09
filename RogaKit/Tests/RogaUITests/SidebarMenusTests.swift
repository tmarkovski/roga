import GitCore
import MenuUI
import Testing
@testable import RogaUI

/// What the sidebar's rows offer in their menus.
@Suite
struct SidebarMenusTests {
    private let main = Worktree(path: "/code/agents-demo", head: ObjectID(hex: "86b3386aa0000000000000000000000000000000"), branch: "refs/heads/main", isMain: true)
    private let linked = Worktree(path: "/agents/fix-login", head: ObjectID(hex: "86b3386aa0000000000000000000000000000000"), branch: "refs/heads/agent/fix-login")

    private func titles(_ entries: [RefMenu.Entry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .command(let title, _, _, _, _): title.plain
            case .divider: "—"
            case .header(let title): "# " + title.plain
            case .choice(let choice): "> " + choice.title
            case .option(let title, let isChecked, _): (isChecked ? "✓ " : "  ") + title.plain
            case .submenu(let title, _, _, _): title.plain + " ▸"
            }
        }
    }

    @Test func theListsMenuSaysHowItsArrangedAndHasTheChoicesInSubmenus() throws {
        var grouping: [Bool] = []
        var sorting: [SidebarSort] = []
        let entries = SidebarMenus.arrangement(
            groupsByOrganization: false,
            sort: .changes,
            setGrouping: { grouping.append($0) },
            setSort: { sorting.append($0) }
        )
        #expect(titles(entries) == ["Group by ▸", "Sort by ▸"])
        guard case let .submenu(_, groupValue, _, groups) = entries[0], case let .submenu(_, sortValue, _, sorts) = entries[1] else {
            Issue.record("Both rows are submenus.")
            return
        }
        #expect(groupValue == "None")
        #expect(sortValue == "Uncommitted changes")
        #expect(titles(groups) == ["  Organization", "✓ None"])
        #expect(titles(sorts) == ["  Name", "✓ Uncommitted changes"])
        if case let .option(_, _, action) = groups[0] { action() }
        if case let .option(_, _, action) = sorts[0] { action() }
        #expect(grouping == [true])
        #expect(sorting == [.name])
    }

    private func command(_ title: String, in entries: [RefMenu.Entry]) -> (isEnabled: Bool, action: () -> Void)? {
        for case let .command(found, _, isEnabled, _, action) in entries where found.plain == title {
            return (isEnabled, action)
        }
        return nil
    }

    private func repositoryActions(newWorktree: @escaping () -> Void = {}) -> SidebarMenus.RepositoryActions {
        SidebarMenus.RepositoryActions(openInNewWindow: {}, newWorktree: newWorktree, locate: {}, remove: {}, reveal: { _ in }, openInTerminal: { _ in })
    }

    private func worktreeActions(newWorktree: @escaping () -> Void = {}) -> SidebarMenus.WorktreeActions {
        SidebarMenus.WorktreeActions(openInNewWindow: {}, newWorktree: newWorktree, locate: {}, delete: {}, reveal: { _ in }, openInTerminal: { _ in })
    }

    // MARK: A repository's row

    @Test func anOpenRepositoryOffersNewWorktreeBesidesItsFolder() throws {
        var started = 0
        let entries = SidebarMenus.entries(forRepository: main, cantOpen: false, actions: repositoryActions { started += 1 })
        #expect(titles(entries) == ["Open in new window", "—", "New worktree…", "Show in Finder", "Open in Terminal", "—", "Remove from sidebar"])
        let newWorktree = try #require(command("New worktree…", in: entries))
        #expect(newWorktree.isEnabled)
        newWorktree.action()
        #expect(started == 1)
    }

    @Test func aBareRepositoryOffersNoNewWorktree() {
        let bare = Worktree(path: "/code/agents-demo.git", isMain: true, isBare: true)
        let entries = SidebarMenus.entries(forRepository: bare, cantOpen: false, actions: repositoryActions())
        #expect(titles(entries) == ["Open in new window", "—", "Show in Finder", "Open in Terminal", "—", "Remove from sidebar"])
    }

    @Test func aRepositoryThatCantOpenOffersOnlyToLocateOrRemoveIt() {
        let entries = SidebarMenus.entries(forRepository: nil, cantOpen: true, actions: repositoryActions())
        #expect(titles(entries) == ["Locate…", "—", "Remove from sidebar"])
    }

    @Test func aRepositoryStillOpeningOffersOnlyToRemoveIt() {
        let entries = SidebarMenus.entries(forRepository: nil, cantOpen: false, actions: repositoryActions())
        #expect(titles(entries) == ["Remove from sidebar"])
    }

    // MARK: A linked worktree's row

    @Test func aLinkedWorktreeOffersNewWorktreeFromItsBranch() {
        var started = 0
        let entries = SidebarMenus.entries(forWorktree: linked, isDeleting: false, actions: worktreeActions { started += 1 })
        #expect(titles(entries) == ["Open in new window", "—", "New worktree…", "Show in Finder", "Open in Terminal", "—", "Delete…"])
        command("New worktree…", in: entries)?.action()
        #expect(started == 1)
    }

    @Test func aWorktreeBeingDeletedCantStartANewOne() {
        let entries = SidebarMenus.entries(forWorktree: linked, isDeleting: true, actions: worktreeActions())
        #expect(command("New worktree…", in: entries)?.isEnabled == false)
        #expect(command("Delete…", in: entries)?.isEnabled == false)
    }

    @Test func aWorktreeWithoutCommitsIsDeletedWithoutAChoice() {
        let unborn = Worktree(path: "/agents/new", branch: "refs/heads/new")
        let entries = SidebarMenus.entries(forWorktree: unborn, isDeleting: false, actions: worktreeActions())
        #expect(titles(entries).last == "Delete worktree")
    }

    @Test func aWorktreeWhoseFolderIsMissingOffersToFindItOrDeleteIt() {
        var missing = linked
        missing.isPrunable = true
        let entries = SidebarMenus.entries(forWorktree: missing, isDeleting: false, actions: worktreeActions())
        #expect(titles(entries) == ["Locate…", "—", "Delete…"])
    }
}
