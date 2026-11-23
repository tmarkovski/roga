# 95. A repository's worktrees as tabs

Accepted on 2026-11-21. This replaces the repository's chip and its menu of worktrees from [decision 40](0040-the-repositorys-name-opens-a-menu-of-its-worktrees.md), moves the branch's chip, its counts, Fetch, New Branch and history's commands from [decisions 19](0019-pull-and-push-from-the-branch-in-the-title-row.md) and [45](0045-fetch-and-new-branch-as-buttons-and-the-commit-count-with-history.md) to a row of their own under the title row, makes the sidebar's worktree rows from [decision 17](0017-a-line-and-a-row-for-a-repositorys-worktrees.md) a choice, and has the menu bar's New Worktree… from [decision 82](0082-make-worktrees-from-the-sidebar-where-theyre-listed.md) open on a tab.

## Context

[Decision 13](0013-repositories-in-a-sidebar.md) moved repositories out of tabs and into the sidebar, because a strip of repositories got crowded past about eight and a worktree in a tab of its own looked like another repository. Both problems came from putting repositories in the tabs.

Someone running several agents in one repository moves between its worktrees far more often than between repositories, and the window made that the slower move. The repository's chip opened a menu of them, which took two clicks and hid what each was doing until it opened. The sidebar listed them too, but under every other repository, where a long list of repositories pushes them out of view.

A worktree is a checkout of its own, with its own files, branch and agent, so it already behaves like a tab: something to switch to, glance at and leave running. Most repositories have a handful of worktrees, which fit in a strip, where most people have more repositories than that.

## Decision

**The title row holds the shown repository's worktrees as tabs.** The repository's own folder, its main worktree, comes first under the repository's name, with a folder icon, and can't go away. A thin line separates it from a tab for each linked worktree, in the order git lists them, and a + button after the last tab opens the popover for a new worktree from the main worktree. The tabs are Command-1 to Command-9 in that order, as View › Show Worktree's rows were, and Control-Tab and Control-Shift-Tab go to the next and the previous tab.

**Each tab says what the sidebar's row said.** A tab has a mark, its name, and one number:

- **The mark** is an agent waiting for you, then conflicts, in red, then an agent at work or one that finished, as the sidebar's marks are. Otherwise it's a lock for a locked worktree, the folder icon on the repository's tab, and the worktree icon on the others, the one the sidebar's menus use for a worktree.
- **The name** is the branch's, with the part up to its last slash in gray, as in `agent/` `fix-login`, so that tabs read by what tells them apart. It fades out at its end when the strip is short of room, as names in the sidebar do (decision 51).
- **The number** is the most pressing of what's waiting: uncommitted files with conflicts in red, a triangle when git can't list them, uncommitted files in orange, then `↓3`, then `↑2`, both in gray, because clicking a tab moves to it rather than pulling or pushing (decision 19). A branch that has never had an upstream counts its `↑` against the main branch and the main branch's upstream, as the refs panel does, so that a worktree whose commits haven't gone anywhere doesn't look like one with nothing waiting.
- **The tooltip** has the whole name, the shortcut, and what the menu of worktrees used to say on its second line, ending with the folder.

The tab the window shows is white in the light theme and a lighter gray than the row in the dark, has an edge and casts a soft shadow, and the others fill with gray under the pointer, as in the Claude app. The row behind the tabs is a light gray, as the Claude app's is, so that the white tab stands out from it, and the refs panel's header beside it is the same gray, so the band runs across the top of the window. The branch's row under the tabs stays the panels' color.

**A tab has no close button.** It keeps a place at its end for its number, and on hover a … button covers the number, as a sidebar row's menu button covers its mark (decision 58). The button opens the menu of the worktree's row in the sidebar, which right-clicking the tab opens too, and the repository's tab opens the repository's menu. A worktree goes away with Delete… in that menu, as it does in the sidebar, rather than by closing its tab. New worktree… in a tab's menu opens the popover on that tab, or on the + button for the repository's tab, and so does the menu bar's New Worktree…, since the tabs show whether or not the sidebar does.

**A row under the tabs holds the branch and what acts on it.** It's as tall as a panel's header and lines up with the refs panel's. It has the branch's chip with its counts, which pull and push, at its left, and Fetch, New Branch, a thin line and history's number of commits and order at its right, all as they were in the title row. When the row is short of room, the number of commits goes first, then the branch's name is cut short.

**The sidebar can list only repositories.** The menu beside Repositories has **Show worktrees** after Group by and Sort by, with a checkmark while it's on, and the View menu has **Show Worktrees in Sidebar**. It's one setting for every window, and it starts off, because the tabs list the worktrees. With it off, a repository's row stands for all its worktrees: it's selected while the window shows any of them, a click goes back to the one the window showed last there, its count adds up their uncommitted files, and its mark and second line are for the most urgent of them. With it on, the sidebar lists worktrees as before.

## Consequences

- Moving between worktrees is one click or one key, and every worktree's state shows without opening anything.
- The repository's name is still on screen while the window shows a linked worktree, on the first tab, so nothing else in the title row has to say which repository it is.
- The title row loses Fetch, New Branch and history's commands, and the middle column loses 40 points to the branch's row. The refs panel's header already took that height beside it.
- A repository with more worktrees than fit squeezes its tabs down to a few letters each. A menu for the tabs that don't fit, which the menu of worktrees could become, isn't built yet.
- The design proposal also had the branch the worktree started from before its name, as in `main → agent/fix-login`, with how far main has moved and a Rebase button, and a pill that goes to the next agent waiting for you. Neither is built yet.
