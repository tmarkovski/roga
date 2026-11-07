# 54. Menus as wide as their rows, and shortcuts for the worktree on screen

Accepted on 2026-11-07. This changes the width that the menus Roga draws itself were given when the refs panel's and history's menus got their own rows, and settles what Command-1 to Command-9 do, which [decision 53](0053-organizations-as-groups-in-the-list-and-add-and-settings-at-the-top.md) left free. It adds shortcuts to the menu of the repository's worktrees from [decision 40](0040-the-repositorys-name-opens-a-menu-of-its-worktrees.md).

## Context

Every menu that `RefMenu` draws was at least 264 points wide, a number measured from a screenshot of a menu we wanted to match, and a menu of only options, such as Group and Sort, at least 180. Most of these menus have short titles, so they were much wider than what's in them. History's menu for a commit, with **Revert…** and **Delete…**, was 264 points wide, where macOS draws the same two items in a menu 82 points wide. macOS has no least width for its menus, and fits them to their items.

The menu of the repository's worktrees in the title row had no shortcuts, and neither did Show in Finder, Open in Terminal or New Worktree…, which it and the sidebar's menus offer. Switching between worktrees meant opening that menu or the sidebar.

Apple's guidelines say that a context menu doesn't show keyboard shortcuts, because it's already a quick way to its commands, and that the shortcuts belong in the menu bar. A menu that opens from a button, like a pop-up or pull-down menu, shows them, as the branch's menu in the title row already does.

## Decision

**A menu that Roga draws is as wide as its rows need**, as macOS's own are, and at least 120 points, so that one of a word or two isn't a sliver. A long name still widens it up to 480 points before it's cut short. Menus of options don't have a width of their own any more.

**The worktree on screen gets three shortcuts** in the menu bar:

| Command | Shortcut | Where |
| --- | --- | --- |
| New Worktree… | Shift-Option-Command-B | The Branch menu, after New Branch…, whose Shift-Command-B it pairs with |
| Show in Finder | Option-Command-R | The File menu, as VS Code has it |
| Open in Terminal | Control-` | The File menu, as GitHub Desktop has it |

**Command-1 to Command-9 show the repository's worktrees**, the first nine in the order the title row's menu lists them, which is the main worktree first and then the linked ones in the sidebar's order. View > Show Worktree lists them with their keys, with a checkmark on the one on screen. A worktree whose folder is missing, or that's being deleted, can't be shown, so its key does nothing.

**The menu of the repository's worktrees shows each row's shortcut** at its right, in gray, as macOS does: Command-1 to Command-9 after each worktree's count, and the three keys after the commands. The keys line up in a column, and each modifier symbol sits right before its key. A worktree past the ninth has no shortcut but keeps the column's room, so the counts stay in line. The shortcut is the row's `NSMenuItem` key equivalent too, so VoiceOver can read it, and pressing it while the menu is open chooses the row.

**Context menus don't show shortcuts.** That covers the menus for right-clicking a ref, a commit or a row in the sidebar. The sidebar's "…" buttons open the same menus as a right-click, and they act on the row under the pointer, where these shortcuts act on the worktree on screen, so they don't show them either.

## Consequences

- Menus of a word or two are about half as wide as they were. The refs panel's menus are still as wide as the ref's name, which is their heading.
- Command-1 to Command-9 change meaning from one repository to another, and as worktrees come and go. That's how a browser's Command-1 to Command-9 work for its tabs.
- Control-` is typed with the key left of 1 on a US keyboard, which other layouts put elsewhere. The command is still in the File menu.
- Pressing a shortcut while the title row's menu is open was checked with `NSMenu`'s own handling of key equivalents in a test, not by pressing the keys in a menu on screen.
