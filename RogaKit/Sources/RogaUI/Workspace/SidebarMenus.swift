import GitCore
import MenuUI

/// What the sidebar's rows offer, in their context menus and in the menus their
/// "…" buttons open, which are the same.
///
/// New Worktree… is here as well as in the title row's menu of worktrees
/// (decision 40), because the sidebar is where each repository's worktrees
/// show. It shows the row's worktree in the window first, since New Branch
/// hangs off the title row and starts from the branch of the worktree on
/// screen.
enum SidebarMenus {
    /// What a repository's row does.
    struct RepositoryActions {
        var openInNewWindow: () -> Void
        /// Shows the main worktree and opens New Branch with In a new worktree
        /// ticked.
        var newWorktree: () -> Void
        /// Asks where a repository that can't be found is now.
        var locate: () -> Void
        var remove: () -> Void
        var reveal: (String) -> Void
        var openInTerminal: (String) -> Void
    }

    /// What a linked worktree's row does.
    struct WorktreeActions {
        var openInNewWindow: () -> Void
        /// Shows the worktree and opens New Branch with In a new worktree
        /// ticked, starting from its branch.
        var newWorktree: () -> Void
        /// Asks where a worktree whose folder is missing is now, and mends git's
        /// links to it there.
        var locate: () -> Void
        var delete: () -> Void
        var reveal: (String) -> Void
        var openInTerminal: (String) -> Void
    }

    /// A repository's menu.
    ///
    /// - Parameters:
    ///   - main: The main worktree, or the bare repository's entry, once the
    ///     repository is open.
    ///   - cantOpen: Whether it's missing or git couldn't open it, which Locate…
    ///     is for.
    static func entries(forRepository main: Worktree?, cantOpen: Bool, actions: RepositoryActions) -> [RefMenu.Entry] {
        var entries: [RefMenu.Entry] = []
        if let main {
            entries += [.command("Open in New Window", action: actions.openInNewWindow), .divider]
            // A bare repository has no files to start a branch in, as in the
            // title row.
            if !main.isBare {
                entries.append(.command("New Worktree…", action: actions.newWorktree))
            }
            entries += [
                .command("Show in Finder") { actions.reveal(main.path) },
                .command("Open in Terminal") { actions.openInTerminal(main.path) },
                .divider,
            ]
        } else if cantOpen {
            entries += [.command("Locate…", action: actions.locate), .divider]
        }
        entries.append(.command("Remove from Sidebar", action: actions.remove))
        return entries
    }

    /// A linked worktree's menu, with its one deleting row. With a branch that
    /// could go too, the dialog asks how far to go, which the ellipsis says.
    /// Without one, it may not ask at all.
    ///
    /// A worktree whose folder is missing has nothing to open, show or start a
    /// branch from, so it offers to find the folder, or to delete the worktree
    /// when the folder really is gone. `git worktree remove` clears what git
    /// keeps for a folder that's gone, and only for that one, where
    /// `git worktree prune` would clear every missing folder's, including one on
    /// a disk that isn't mounted.
    static func entries(forWorktree worktree: Worktree, isDeleting: Bool, actions: WorktreeActions) -> [RefMenu.Entry] {
        let delete = RefMenu.Entry.command(worktree.canDeleteBranch ? "Delete…" : "Delete Worktree", isDestructive: true, isEnabled: !isDeleting, action: actions.delete)
        if worktree.isPrunable {
            return [.command("Locate…", isEnabled: !isDeleting, action: actions.locate), .divider, delete]
        }
        return [
            .command("Open in New Window", action: actions.openInNewWindow),
            .divider,
            .command("New Worktree…", isEnabled: !isDeleting, action: actions.newWorktree),
            .command("Show in Finder") { actions.reveal(worktree.path) },
            .command("Open in Terminal") { actions.openInTerminal(worktree.path) },
            .divider,
            delete,
        ]
    }
}

extension Worktree {
    /// Whether it has a branch that can go with it. A branch without commits
    /// yet has nothing to delete.
    var canDeleteBranch: Bool {
        branch != nil && head != nil
    }
}
