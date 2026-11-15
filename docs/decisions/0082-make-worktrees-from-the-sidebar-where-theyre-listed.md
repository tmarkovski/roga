# 82. Make worktrees from the sidebar, where they're listed

Accepted on 2026-11-15. This changes [decision 40](0040-the-repositorys-name-opens-a-menu-of-its-worktrees.md), whose menu of worktrees in the title row ended with New Worktree…, Show in Finder and Open in Terminal, and [decision 45](0045-fetch-and-new-branch-as-buttons-and-the-commit-count-with-history.md), which hung every popover for a new branch from the New Branch button, New Worktree… included. It also lets a repository's row move its count on hover, which [decision 58](0058-the-mark-under-the-menus-button-and-the-count-before-it.md) kept still.

## Context

We went through the window looking for buttons that sit away from what they act on. Worktrees were the clearest case. The sidebar is where they're listed and managed, yet making one ended in the title row's corner.

- New Worktree… in a sidebar row's menu showed that worktree in the window first, because New Branch starts from the branch of the worktree on screen. Then the popover opened under the New Branch button, across the window from the row that asked for it.
- The repository's menu in the title row had New Worktree…, Show in Finder and Open in Terminal as well. Every row's menu in the sidebar has the same three, and so does the menu bar.
- Making a worktree from the sidebar took a hover, the "…" button and a choice from its menu. Conductor, whose groups the sidebar follows ([decision 53](0053-organizations-as-groups-in-the-list-and-add-and-settings-at-the-top.md)), puts a + on each repository for this.

## Decision

**The popover for a new worktree hangs from the sidebar row it was asked for on,** at the row's right edge, opening into the window as Add Repositories' popover does. It starts from that row's worktree, so the window doesn't show that worktree first, and its title says where, as in **New Worktree from main**. It has a field for the branch's name and the exact command, `git worktree add -b <name> ../<name>`, with no checkbox, since a worktree is what it makes. Return makes it, and the window then shows the new worktree, whose row appears under its repository. The row keeps its gray while the popover is open, to say where it came from.

**A repository's row has a + on hover,** just before its menu's "…" button, which opens that popover from the main worktree. Its tooltip says where it starts, as in **New Worktree from main**. A bare repository, or one Roga can't open, has none. The two buttons take two places at the right edge, so while the pointer is over a repository's row, its count moves left by one place. A worktree's row keeps only the "…" button, and New worktree… in its menu.

**The menu bar's New Worktree…,** Shift-Option-Command-B, opens the popover on the selected row, scrolling the sidebar to it. While the sidebar is hidden there's no row to hang it from, so it opens New Branch in the title row with In a new worktree ticked, as before.

**The repository's menu in the title row lists only the worktrees.** It's for seeing which one the window shows and switching to another, which still matters while the sidebar is hidden, and its rows keep Command-1 to Command-9. New Worktree…, Show in Finder and Open in Terminal leave it, and stay in the sidebar's menus and the menu bar.

**New Branch keeps In a new worktree.** Starting a branch for an agent from the title row is still the quickest way there, and that popover is about the branch.

## Consequences

- A worktree is made where it will be listed, and making one doesn't move the window first.
- Making a worktree that starts from a worktree the window doesn't show runs git from the window rather than from that worktree's model, which may not exist. When the model does exist and is running git, the popover says to try again once it's done, as the title row waits.
- The count on a repository's row no longer stays put on hover. It still shows, one place to the left. Rows for worktrees are as decision 58 has them.
- The popover hangs from the row rather than from the +, because the + goes once the pointer leaves the row, and a popover closes with what it hangs from.
- History's Create › Worktree starts from a commit rather than a worktree, so it stays in history's menu. [Decision 83](0083-open-a-new-refs-popover-where-it-was-asked-for.md) hangs its popover from the row that was right-clicked.
