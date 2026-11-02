# Main window

This is the rough wireframe of yaga's main window for release 1. It settles the overall layout. Details will change as we build the real views.

The layout follows the Claude and ChatGPT apps. A sidebar on the left lists repositories with their worktrees under them, the selected worktree's history and diffs fill the middle, and a panel on the right lists the repository's branches, remotes, tags and stashes. Every section in the middle is a plain rectangle with its own header. [Decision 13](decisions/0013-repositories-in-a-sidebar.md) explains why repositories moved out of tabs and into the sidebar. The [main window preview](../prototypes/main-window/README.md) still shows the earlier layout, with tabs on top and worktrees in a navigator on the right.

```text
┌─────────────────────┬──────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  ◧            │ agents-demo / main                                                      ▤  ◨ │
│ + Open repository   ├────────────────────────────────────────────────────┬─────────────────────────┤
│ ⌕ Search            │ History  128 commits          ⑂ All branches  ≡  ⋯ │ Refs               ⇅  ⋯ │
│                     ├────────────────────────────────────────────────────┼─────────────────────────┤
│ Repositories        │ ○  3 uncommitted files                             │ ⌕ Filter                │
│ agents-demo ▾       │ ●  agent/fix-login  Add login tests        48ba644 │ Branches ▾            4 │
│   main              │ ●  ✓ main  Update the changelog            5405371 │   main                ✓ │
│   agent/add-tests 4 │ ●  Add parser tests                        bb3b6b6 │   agent/add-tests    ↑1 │
│   agent/fix-login 3 │ ●  v0.2  Show an error when …              86b3386 │   agent/fix-login ↑3 ↓2 │
│   agent/refactor-…  ├──────────────────────┬─────────────────────────────┤   agent/refactor-…   ↑5 │
│ yaga ▾              │ Commit 5405371  ⧉  ⋯ │ CHANGELOG.md        ⌕  ↗  ⋯ │ Remotes ▾             1 │
│   gitrunner      19 ├──────────────────────┼─────────────────────────────┤   origin                │
│ linux ▸             │ Update the changelog │ @@ -1,6 +1,10 @@            │ Tags ▾                2 │
│ git ▸               │ Author, date, parent │   # Changelog               │ Stashes ▾             0 │
│                     │ CHANGELOG.md  +4 −0  │ + ## 0.3                    │                         │
└─────────────────────┴──────────────────────┴─────────────────────────────┴─────────────────────────┘
```

## The sidebar

The sidebar runs the full height of the window on the left, with the traffic lights at its top. It's a shade darker than the panels, and a thin gray line separates it from them, from the top of the window to the bottom, as in the Claude app. It's the sidebar macOS provides, so the button next to the traffic lights, the View menu and the usual shortcut all hide it. That button is a plain icon that gets a gray square on hover, like the icon buttons in panel headers, rather than the glass button macOS draws. It stays next to the traffic lights while the sidebar is hidden.

Every row in the sidebar fills with gray while the pointer is over it, and the selected worktree's row keeps a slightly darker gray. The fill has 8-point corners and leaves 8 points on each side. Rows are 32 points tall, or 54 with a second line, with 2 points between them, as in the Claude app. A row's top right corner shows a label, which gives way to the row's commands on hover: 24-point buttons 4 points from the top and right edges, so they sit beside the first line of a two-line row. The sidebar draws these rows itself, because a macOS sidebar list can't, so it also handles the arrow keys: up and down move between worktrees, and right and left show and hide the worktrees of the selected one's repository.

- Its top rows are actions. Release 1 has one, opening a repository. Cloning one joins it in release 2, and search after the release 1 cut line. An action's icon is the same color as its label, and its keyboard shortcut shows at the right in a secondary color on hover.
- Below them, it lists every repository the user has added, until the user removes it ([decision 14](decisions/0014-the-sidebar-keeps-every-added-repository.md)). Each repository is a group: its name in bold, with a small triangle after the name that collapses or expands it. Under the name is the folder the repository is in, as in `~/git`, which tells apart clones with the same name and stays in view while the group is collapsed. Its label is the number of worktrees it has besides the main one, after an icon of two overlapping squares, and it has no label without any. While it's collapsed, the label adds the number of uncommitted files in all of its worktrees, in orange. On hover, buttons for Show in Finder, Open in Terminal and a menu with Remove from Sidebar take its place. A repository yaga can't find is dimmed, its label says so, and its menu can find it again or remove it.
- Each of the repository's worktrees has a row under it. The first line is the worktree's branch. The second is its folder and how long ago something in it changed, as in `fix-login · writing now`. The number of uncommitted files sits at the right in orange.
- Clicking a worktree row shows that worktree in the rest of the window. On hover, the count gives way to buttons that open the worktree in a new window or in Terminal, and its context menu has those and Show in Finder.

## The title row

The top row of the middle and right columns names what the window shows, as in `agents-demo / main`. Its right end holds buttons that apply to the whole window: the log of git commands yaga ran (later), and showing or hiding the refs panel. Dragging the empty part of the row moves the window, and double-clicking it does what the user chose in System Settings.

## Panels

Every section in the middle is a panel: a plain rectangle with a 40-point header, separated from its neighbors by thin lines rather than cards or shadows. A header reads from left to right, from what the panel shows to what you can do with it:

- The left side says what the panel shows: a title or a file's path.
- Any state the panel depends on comes next, as a chip with a small triangle, such as which branches the history includes or which two commits a diff compares.
- The panel's commands follow as icon buttons with tooltips. An icon button is a thin, dark glyph that gets a rounded gray square when the pointer is over it, like the Claude app's.
- A menu for more commands comes last. It lists every command the panel has, including the ones shown as buttons, with their keyboard shortcuts. Every command is also in the menu bar.
- When several things in a panel are selected, such as files in release 2, the header can switch to commands that act on the selection.
- Dragging the lines between panels resizes them. The height and width of the commit panel are one setting each for every window. The panels above and below the line stay at least 100 points tall, and those beside it at least 180 points wide.

## The history panel

The history panel fills the top of the middle column.

- The right side of its header shows which branches the history includes, a switch between topological order and date order (decision 12), and a menu for more commands.
- It lists commits with the graph, then the commit's refs as colored badges, its subject, author, date and short hash. The current branch is green with a checkmark, local branches are blue, remote branches are purple, and tags are orange.
- While the worktree has uncommitted files, a row for them comes first, with a hollow dot and how many files there are ([decision 15](decisions/0015-uncommitted-changes-as-a-row-in-history.md)). A line runs from it to the commit `HEAD` points to, past any commits above `HEAD`, and past 100 rows it's cut into two arrows, as other long lines are. A worktree with no changes has no row. The row appears, goes and updates when yaga becomes the active app, when the window shows the worktree again, and on View > Reload. A ref that moved loads history again at the same moments.
- When history takes more than a second to load, the panel says under the spinner why, if it's because the repository has no commit-graph file that yaga can use, and what yaga is doing about it ([decision 6](decisions/0006-keep-the-commit-graph-up-to-date.md)). Once history shows, a repository with at least 50,000 commits keeps a note after the commit count: **Writing commit-graph file…** while git writes it, or **Opens slowly** with a tortoise when yaga won't or can't write one. The note's tooltip gives the reason.

## The commit and diff panels

Two panels sit under the history panel.

- **The commit panel** shows the selected commit: its subject and message, author, date and parents, and the files it changed with the lines added and removed in each. Its header shows the short hash and a button that copies the full hash, which Edit > Copy Commit Hash and Shift-Command-C do too. It shows the committer as well when that differs from the author. Clicking a parent's hash selects the parent in history. A merge lists what changed compared with its first parent, and says so. With nothing selected, which is how a worktree opens, the panel asks you to select a commit. Selecting a commit selects its first file. Clicking a file selects it, and then the up and down arrows move through the list. View > Next File and Previous File, Option-Command-Down Arrow and Option-Command-Up Arrow, do the same while the keyboard is in history.
- **The diff panel** shows the selected file's changes as a unified diff without wrapping, with backgrounds for added lines, removed lines and hunk headers. A strip on the left has each line's numbers in the old and new file and its `+` or `−`, which stay put as the text scrolls sideways, and which a selection doesn't copy. Its header shows the file's path, with the folders in gray and the file name in full color, then where a moved file came from and how its mode changed, and a button for finding text, which Edit > Find in Diff and Command-F do too. A file with no lines to compare, such as a binary file, gets a sentence saying what changed. The header will have buttons for opening the file in an editor, and more, and changed words will be highlighted.
- **With the row for uncommitted changes selected**, a panel titled Uncommitted Changes takes the commit panel's place. It lists the files under the headings Conflicts, Unstaged, Untracked and Staged, each with how many files it has and how many lines they change, in the same rows as a commit's files. A file with both staged and unstaged changes is listed under both, and each row selects its own diff. An untracked file shows no line counts. The diff panel's header says which heading the file is under, and a conflicted file's diff compares the worktree with `HEAD`, so its conflict markers show as added lines. Selecting the row selects the first file. When the files are read again, the selected file stays selected and its text stays at the same place, even if the file changed. Once it has no changes, the first file is selected, and once there are no uncommitted files, nothing is.

## The refs panel

The refs panel is on the right. It's a shade darker than the panels, like the sidebar. It's the inspector macOS provides, and the button at the right end of the title row hides it, as View > Hide Refs and Control-Command-I do. It's 288 points wide, and it can be dragged up to 400.

When the window gets too narrow to keep 400 points for the middle, the panel gives way, and its button and menu command are disabled until there's room. It comes back by itself when the window is wide enough again, unless the user had closed it. Decision 13 expected the panel to be what gives way first.

- Its header has the title **Refs**, a button that sorts by name or by date, and a menu with every command the panel has. A filter field below the header narrows every section at once, by the names of branches, remotes and tags and the messages of stashes, and it opens any section that's collapsed. View > Filter Refs and Option-Command-F go to it, showing the panel first if it's hidden. The down arrow goes from the field to the first row, and Escape clears it.
- Its sections are **Branches**, **Remotes**, **Tags** and **Stashes**. A section's header shows its title with a small triangle after it, and clicking the header collapses or expands the section, which is one setting for every repository. The header shows how many items the section has, stays in view while its rows scroll, and on hover it will show the section's commands, such as creating a branch or tag in release 2.
- Clicking a branch, remote branch or tag selects its commit in history, whichever worktree has it checked out. After that the up and down arrows move through the rows, skipping remotes, stashes and anything else with no commit to select.
- A branch row shows the branch's name. Its second line says which worktree has it checked out and how far it is ahead of or behind the branch it's compared with, as in `in fix-login · 3 ahead, 2 behind main`, or when it last changed if neither applies, and the same counts sit beside the name as arrows. A branch is compared with its upstream, or without one, with the repository's main branch: the one `origin/HEAD` names, or a local `main` or `master`. The branch checked out in the window's worktree comes first and has a checkmark. On hover, a branch that another worktree has checked out shows a button that switches the window to that worktree. The buttons that hide a branch from history and review it against its base come with those features.
- A remote shows its address, without the user name or password in its URL, with its branches under it and each one's date. A remote that has branches left but isn't configured any more says so. A tag shows the subject of the commit it points to. A stash shows its message, what git calls it and when it was made, and clicking one doesn't do anything until the panels can show what's in it.
- By name, branches and remote branches go from A to Z and tags go from the latest version to the oldest, and numbers in names count as numbers, so `v0.10` is newer than `v0.9`. By date, they all go from the latest to the oldest. Stashes keep git's order, which is already that.

## Colors and type

- Surfaces are plain, with thin gray lines between sections. The sidebar and the refs panel are a shade darker. Dark mode keeps the same structure in dark grays.
- Selection is a soft gray fill, not the accent color. The accent color is kept for the graph.
- Text uses the system font at 12.5 to 13 points. The sidebar's rows use 14 points, with 13 for a second line and for shortcuts, as the Claude app's sidebar does. Hashes and diffs use the monospaced system font.

## Options we're keeping open

We sketched several ways to show uncommitted changes. [Decision 15](decisions/0015-uncommitted-changes-as-a-row-in-history.md) chose the row at the top of history for release 1, and these others are worth revisiting now that the real views exist.

- **Changes as its own view**, the way Fork does it: unstaged files on top, staged files below, and in release 2 the commit message under them, so files move down toward the commit. Each list is a panel with its own title, count and commands. This earns its place once staging arrives in release 2.
- **One review pane for every set of changes**, like the diff panes in the Claude and ChatGPT apps. Chips in the header choose what to compare, such as uncommitted changes, a branch against its base, one commit or a stash, and show the lines added and removed. Every file is a collapsible block in one scrolling diff, with a check for marking it viewed, and a tree of files on the right jumps between them. This could be where branch review and stashes appear. Showing many files in one scrolling diff needs a prototype first, because decision 9's text view shows one file at a time.
- **Tabs in a panel's header**, from the ChatGPT app's pane for changes, so that several comparisons can stay open at once.

[Decision 13](decisions/0013-repositories-in-a-sidebar.md) lists the other places we sketched for repositories.

## Still open

- How repositories are reordered in the sidebar: by dragging, or with commands that move one up or down.
- How often the sidebar updates the uncommitted counts of repositories that aren't showing.
- What gives way after the refs panel when the window gets narrow, such as a sidebar someone dragged wide.
- What Command-1 to Command-9 and Control-Tab do now that there are no tabs, such as selecting repositories in the sidebar.
- Which keyboard shortcut goes to the row for uncommitted changes, which can be scrolled out of view.
- Whether a worktree with uncommitted changes opens with their row selected.
- Whether untracked files show how many lines they have, which takes reading each one.
- Where branch review, file history and the contents of a stash appear. The review pane above is one answer.
- How wide the commit panel is by default, and whether it can be hidden.
- Whether a worktree opens with `HEAD` selected, rather than with nothing selected.
- Whether going to another commit should stay on the same file, if the commit changed it, rather than selecting the first one.
- Whether a commit's long message should push its files down, now that the files are how you get around the diff.
- Whether the diff's tabs should be as wide as they are in a terminal, which is 8 columns.
