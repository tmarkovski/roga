# 52. Organizations as groups in the list, and Add Repositories and Settings at the top

Accepted on 2026-11-07. This supersedes the rail of [decision 16](0016-a-rail-of-organizations-in-the-sidebar.md): picking one organization at a time, Command-1 to Command-9, View > Hide Organizations, and each window remembering its organization and the worktree it last showed there. It supersedes [decision 36](0036-a-solid-ink-tile-for-whats-selected-on-the-rail.md), whose ink tile only the rail had, and moves the new version that [decision 43](0043-show-a-new-version-in-the-sidebar-rather-than-sparkles-window.md) put above the rail's gear. It changes [decision 18](0018-every-remote-counts-toward-a-repositorys-organization.md) so that a repository with remotes in two organizations is listed once. Repositories' rows and their worktrees stay as decisions 16, 17, 48 and 51 have them.

## Context

The rail took 56 points of the sidebar's width for tiles of two letters, and showed one organization at a time. Seeing what agents were doing across organizations meant clicking through them, or picking All, which has no groups at all.

The user pointed to Conductor's sidebar, which puts a few actions in rows at the top, under the traffic lights, and arranges the rest under small gray labels that fold. That keeps every organization in one list, where an agent waiting in any of them shows without a click, and folding an organization does what picking another did: it gets the ones you aren't working on out of the way.

## Decision

**Adding repositories and Settings are rows at the top of the sidebar.** Each has an icon in gray and its title, is 32 points tall like the list's rows, and fills with gray on hover. Add Repositories keeps the darker gray while its popover is open, and Settings while its sheet is, because neither is a selection. A new version of Roga is a third row under them, in orange, reading Update to 1.4 or Restart to Update. A line across the sidebar separates these rows from the list.

**The list has a header,** Repositories in bold with how many there are in gray, and at its right a button with sliders that opens a menu of two choices. It's one of Roga's own menus, like a row's, with a checkmark at the right of the option that's chosen rather than the system's at the left:

- **Group By** Organization, the default, or None.
- **Sort By** Name, the default, or Uncommitted Changes.

The View menu has the same, as Group Repositories by Organization, with Control-Command-O, which hid the rail before, and Sort Repositories. Both are one setting for every window, like the refs panel's sort.

**Grouped by organization,** each organization has a label with its name, in 12-point gray, where the text of its rows starts. Organizations go from A to Z, then Other, which lists other owners' repositories as `owner/name` and then the ones without a remote, with no labels of their own between them.

- A label shows a chevron after its name only while the pointer is over it, and clicking it collapses or expands the group. Which groups are collapsed is one setting for every window.
- A collapsed group goes on showing the repository with the selected worktree, as a collapsed repository goes on showing that worktree. Its label has the mark of the most urgent agent among the worktrees it hides, in the column of the rows' marks, so that one waiting for you still shows.
- A repository with remotes in two organizations is listed once, under the first of its owners that has a group, which is `origin`'s when that one does. Decision 18 listed it under both because the rail showed one at a time, and in one list it would be the same row twice. A group with nothing left to list has no label.

**Without groups,** every repository is in one run, as All was.

**Sorted by uncommitted changes,** the repositories whose worktrees have the most uncommitted files, the main one and the linked ones added up, come first, and those with as many go from A to Z. When grouped, this sorts within each group.

## Consequences

- The list gets the rail's 56 points back, and the sidebar stays 312 points wide by default.
- Clicking an organization no longer brings back the worktree last shown there. A window keeps showing what it shows, and one saved by an earlier version still opens, without where its rail was.
- Command-1 to Command-9 are free again.
- The Add Repositories popover lists every clone it finds, since there's no organization picked to narrow it, and its field narrows them by name.
- Sorting by uncommitted changes moves a repository while an agent works in it. Sorting by name keeps every repository where the eye expects it.
- A collapsed group looks like an open one until the pointer is over its label. One that goes on showing the selected repository looks like a group with one repository.
