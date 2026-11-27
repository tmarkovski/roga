import GitCore
import MenuUI

/// What the sidebar's rows offer, in their context menus and in the menus their
/// "…" buttons open, which are the same.
///
/// New Worktree… is here, rather than in the title row's menu of worktrees,
/// because the sidebar is where each repository's worktrees are listed and
/// managed (decision 82). Its popover hangs from the row and starts from the
/// row's worktree, without showing that worktree in the window first.
enum SidebarMenus {
    /// What a repository's row does.
    struct RepositoryActions {
        var openInNewWindow: () -> Void
        /// Opens the popover for a new worktree from the main worktree, on the
        /// row.
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
        /// Opens the popover for a new worktree from this one, on the row.
        var newWorktree: () -> Void
        /// Asks where a worktree whose folder is missing is now, and mends git's
        /// links to it there.
        var locate: () -> Void
        var delete: () -> Void
        /// Takes the lock off a locked worktree.
        var unlock: () -> Void
        var reveal: (String) -> Void
        var openInTerminal: (String) -> Void
    }

    /// The menu that groups and sorts the list, with what's chosen on each row
    /// and the choices in a submenu, and then whether the list has rows for
    /// worktrees, with a checkmark while it does (decision 95).
    ///
    /// - Parameters:
    ///   - showsWorktrees: Whether the list has rows for worktrees, or nil to
    ///     leave that out of the menu.
    static func arrangement(
        groupsByOrganization: Bool,
        sort: SidebarSort,
        showsWorktrees: Bool? = nil,
        setGrouping: @escaping (Bool) -> Void,
        setSort: @escaping (SidebarSort) -> Void,
        setShowsWorktrees: @escaping (Bool) -> Void = { _ in }
    ) -> [RefMenu.Entry] {
        let grouping: [(value: Bool, title: String)] = [(true, "Organization"), (false, "None")]
        var entries: [RefMenu.Entry] = [
            .submenu("Group by", value: grouping.first { $0.value == groupsByOrganization }?.title, entries: grouping.map { option in
                .option(RefMenu.Title(option.title), isChecked: groupsByOrganization == option.value) { setGrouping(option.value) }
            }),
            .submenu("Sort by", value: sort.title, entries: SidebarSort.allCases.map { option in
                .option(RefMenu.Title(option.title), isChecked: sort == option) { setSort(option) }
            }),
        ]
        if let showsWorktrees {
            entries += [
                .divider,
                .option("Show worktrees", isChecked: showsWorktrees) { setShowsWorktrees(!showsWorktrees) },
            ]
        }
        return entries
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
            entries += [.command("Open in new window", action: actions.openInNewWindow), .divider]
            // A bare repository has no files to start a branch in, as in the
            // title row.
            if !main.isBare {
                entries.append(.command("New worktree…", action: actions.newWorktree))
            }
            entries += [
                .command("Show in Finder") { actions.reveal(main.path) },
                .command("Open in Terminal") { actions.openInTerminal(main.path) },
                .divider,
            ]
        } else if cantOpen {
            entries += [.command("Locate…", action: actions.locate), .divider]
        }
        entries.append(.command("Remove from sidebar", action: actions.remove))
        return entries
    }

    /// The menu of a repository that's being cloned, which has nothing to open
    /// yet, so all it can do is stop (decision 113).
    static func entries(forCloning isCancelling: Bool, cancel: @escaping () -> Void) -> [RefMenu.Entry] {
        [.command("Cancel clone", isEnabled: !isCancelling, action: cancel)]
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
    ///
    /// A locked worktree also offers Unlock, just before Delete…, which takes
    /// the lock off without asking, because nothing in the folder changes
    /// (decision 116).
    static func entries(forWorktree worktree: Worktree, isDeleting: Bool, actions: WorktreeActions) -> [RefMenu.Entry] {
        let delete = RefMenu.Entry.command(worktree.canDeleteBranch ? "Delete…" : "Delete worktree", isDestructive: true, isEnabled: !isDeleting, action: actions.delete)
        if worktree.isPrunable {
            return [.command("Locate…", isEnabled: !isDeleting, action: actions.locate), .divider, delete]
        }
        var entries: [RefMenu.Entry] = [
            .command("Open in new window", action: actions.openInNewWindow),
            .divider,
            .command("New worktree…", isEnabled: !isDeleting, action: actions.newWorktree),
            .command("Show in Finder") { actions.reveal(worktree.path) },
            .command("Open in Terminal") { actions.openInTerminal(worktree.path) },
            .divider,
        ]
        if worktree.isLocked {
            entries.append(.command("Unlock", isEnabled: !isDeleting, action: actions.unlock))
        }
        entries.append(delete)
        return entries
    }
}

extension Worktree {
    /// Whether it has a branch that can go with it. A branch without commits
    /// yet has nothing to delete.
    var canDeleteBranch: Bool {
        branch != nil && head != nil
    }
}
