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
            case .command(let title, _, _, _): title
            case .divider: "—"
            case .header(let title): "# " + title
            case .choice(let choice): "> " + choice.title
            case .option(let title, let isChecked, _): (isChecked ? "✓ " : "  ") + title
            }
        }
    }

    private func command(_ title: String, in entries: [RefMenu.Entry]) -> (isEnabled: Bool, action: () -> Void)? {
        for case let .command(found, _, isEnabled, action) in entries where found == title {
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
        #expect(titles(entries) == ["Open in New Window", "—", "New Worktree…", "Show in Finder", "Open in Terminal", "—", "Remove from Sidebar"])
        let newWorktree = try #require(command("New Worktree…", in: entries))
        #expect(newWorktree.isEnabled)
        newWorktree.action()
        #expect(started == 1)
    }

    @Test func aBareRepositoryOffersNoNewWorktree() {
        let bare = Worktree(path: "/code/agents-demo.git", isMain: true, isBare: true)
        let entries = SidebarMenus.entries(forRepository: bare, cantOpen: false, actions: repositoryActions())
        #expect(titles(entries) == ["Open in New Window", "—", "Show in Finder", "Open in Terminal", "—", "Remove from Sidebar"])
    }

    @Test func aRepositoryThatCantOpenOffersOnlyToLocateOrRemoveIt() {
        let entries = SidebarMenus.entries(forRepository: nil, cantOpen: true, actions: repositoryActions())
        #expect(titles(entries) == ["Locate…", "—", "Remove from Sidebar"])
    }

    @Test func aRepositoryStillOpeningOffersOnlyToRemoveIt() {
        let entries = SidebarMenus.entries(forRepository: nil, cantOpen: false, actions: repositoryActions())
        #expect(titles(entries) == ["Remove from Sidebar"])
    }

    // MARK: A linked worktree's row

    @Test func aLinkedWorktreeOffersNewWorktreeFromItsBranch() {
        var started = 0
        let entries = SidebarMenus.entries(forWorktree: linked, isDeleting: false, actions: worktreeActions { started += 1 })
        #expect(titles(entries) == ["Open in New Window", "—", "New Worktree…", "Show in Finder", "Open in Terminal", "—", "Delete…"])
        command("New Worktree…", in: entries)?.action()
        #expect(started == 1)
    }

    @Test func aWorktreeBeingDeletedCantStartANewOne() {
        let entries = SidebarMenus.entries(forWorktree: linked, isDeleting: true, actions: worktreeActions())
        #expect(command("New Worktree…", in: entries)?.isEnabled == false)
        #expect(command("Delete…", in: entries)?.isEnabled == false)
    }

    @Test func aWorktreeWithoutCommitsIsDeletedWithoutAChoice() {
        let unborn = Worktree(path: "/agents/new", branch: "refs/heads/new")
        let entries = SidebarMenus.entries(forWorktree: unborn, isDeleting: false, actions: worktreeActions())
        #expect(titles(entries).last == "Delete Worktree")
    }

    @Test func aWorktreeWhoseFolderIsMissingOffersToFindItOrDeleteIt() {
        var missing = linked
        missing.isPrunable = true
        let entries = SidebarMenus.entries(forWorktree: missing, isDeleting: false, actions: worktreeActions())
        #expect(titles(entries) == ["Locate…", "—", "Delete…"])
    }
}
