# 50. Branches in folders, at each slash of their names

Accepted on 2026-11-06. Brings [decision 31](0031-chevrons-for-what-folds-and-lines-down-a-tree.md)'s chevron to folders of branches in the refs panel, though not its lines down a tree, and moves the current branch, which came first in [the panel's](../main-window.md#the-refs-panel) list of branches, into its folder.

Revised the same day, before any release had it. A folder's row first had its chevron where a branch has its icon, how many branches were under it at the right, and decision 31's line down the folder. Seen in the running app, the count lined up with the remote branches' dates and read as one of them, and the line added nothing to folders that are seldom more than one deep.

## Context

Branch names often start with a prefix and a slash: someone's initials, as in `tm/sidebar-second-line`, a kind of change, as in `fix/` or `feature/`, or a bot's name, as in `dependabot/npm_and_yarn/`. The refs panel listed every branch on one level, so in Roga's own repository every branch but `main` started with `tm/`, and the list under a team's remote could be dozens of one bot's branches. Fork and GitKraken group branches like these into folders, and Roga's own tree of files already has folders that open and close.

## Decision

**Each part of a branch's name before a slash is a folder.** `tm/commit-experience` shows as `commit-experience` in the folder `tm`, and `a/b/c` as `c` in `b` in `a`.

- A folder shows even with one branch in it, so that a branch stays where it is when another one with its prefix comes along.
- Unlike in a tree of files, a folder that holds only another folder doesn't share its row with it. Branch names are seldom that deep, and a shared `tm/agents` row would split in two as soon as a branch went straight into `tm`.
- A remote's branches go in folders of their own, under the remote, by the same rule. Tags stay on one level, because only branches were asked for, and version tags seldom have a slash.

**A folder's row** has a folder where a branch has its icon, so that the column of icons always says what a row is: a cloud for a remote, a branch, or a folder. The folder's name follows in gray, with decision 31's chevron right after it, as a section's header and a repository in the sidebar have theirs. The row is 28 points tall, as a remote's branches are, and clicking it opens or closes the folder.

- What's in a folder starts 22 points further in, as a remote's branches do under the remote, and nothing else ties it to the folder. Decision 31's line down a tree of files helps where folders go several deep, and branch folders seldom go past one.
- How many branches are under a folder is in its tooltip, after its whole path, as in `origin/tm/ · 9 branches`, and VoiceOver reads it. The row doesn't show it. At the right it lined up with the remote branches' dates and the local branches' counts, and right after the chevron, `dependabot › 2` read like a path. An open folder shows its branches anyway.
- The name stays gray, so that a folder doesn't weigh as much as the branches in it.

**A remote's row goes to one line,** as tall as its folders and branches: the cloud, the remote's name, and its address in gray right after the name rather than on a second line. It isn't at the right, where the branches have their dates. An address that doesn't fit is cut short in the middle, which keeps the host and the repository's name, and the tooltip has all of it. The remote's name stays black, and it has no chevron, so it doesn't read as a folder.

**Folders start open, and the panel remembers which ones are closed.** That's one setting for every repository, like the sections. A folder goes by what the full names of its branches start with, as in `refs/heads/tm/` or `refs/remotes/origin/tm/`, so closing origin's `tm` leaves the local `tm` open, and a prefix someone uses in every repository stays closed in all of them. Folders that start closed would tidy a remote with many bots' branches straight away, but would hide someone's own work until they first opened its folder.

**The current branch goes in its folder,** with its checkmark, and comes first among the rows beside it there. A current branch without a prefix still comes first in the list. Keeping it first in the whole list, under its full name, would always have kept it in sight, but it would have been the one branch that isn't where its name says.

**By name, folders come first,** then the other branches, each from A to Z, as in a tree of files. **By date, folders and branches go together** from the latest to the oldest, a folder at the date of the latest branch under it, so that the top of the list is still where the latest work is.

**A filter opens every folder that has a match in it, and shows only the matches.** It matches the whole name, so `tm/` lists everything in `tm`. A flat list of whole names, which the tree of files shows while filtering, would have taken fewer rows, but this keeps each match in the folder where someone is used to finding it.

**The up and down arrows go past folders,** as they already go past remotes, since a folder has no commit to select, and past the branches in a closed folder.

## Consequences

- While the current branch's folder is closed, the panel doesn't show which branch is checked out. The title row still does.
- A branch's title is now only the end of its name, so its tooltip and VoiceOver say `sidebar-second-line`, and the folder above it says the rest. Its menu's heading still has the full name.
- The folder looks like the icon of the Show Worktree button that a branch row shows on hover, which has git's mark inside it.
- Each folder costs 22 points of width. At the panel's default 288 points, a branch in three folders under a remote has about 190 points left for its name and date.
- The section of local branches has rows of two heights, 28 for a folder and 40 for a branch, which the lazy stack can't add up without laying them out. A repository has few local branches. Remotes and tags, the sections that can have thousands, have rows of one height, and remotes only since their rows went to one line.
- The rows are worked out again only when the refs, the order, the filter or the closed folders change, because a remote can have thousands of branches and the arrow keys ask for them on every step.
- **Collapse All Sections** and **Expand All Sections** leave the folders as they are.
- The setting keeps closed folders whose branches are gone, so a folder that comes back is closed again.
