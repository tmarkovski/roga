# Main window

This is the rough wireframe of yaga's main window for release 1. It settles the overall layout. Details will change as we build the real views.

The layout follows the Claude and ChatGPT apps. A sidebar on the left lists repositories with their worktrees under them, the selected worktree's history and diffs fill the middle, and a panel on the right lists the repository's branches, remotes, tags and stashes. Every section in the middle is a plain rectangle with its own header. [Decision 13](decisions/0013-repositories-in-a-sidebar.md) explains why repositories moved out of tabs and into the sidebar. The [main window preview](../prototypes/main-window/README.md) still shows the earlier layout, with tabs on top and worktrees in a navigator on the right.

```text
┌─────────────────────┬──────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  ◧            │ agents-demo / main                                                      ▤  ◨ │
│ + Open repository   ├────────────────────────────────────────────────────┬─────────────────────────┤
│ ⌕ Search            │ ( History | Changes )         ⑂ All branches  ≡  ⋯ │ Refs               ⇅  ⋯ │
│                     ├────────────────────────────────────────────────────┼─────────────────────────┤
│ Repositories        │ ●  agent/fix-login  Add login tests        48ba644 │ ⌕ Filter                │
│ agents-demo ▾       │ ●  ✓ main  Update the changelog            5405371 │ Branches ▾            4 │
│   main              │ ●  Add parser tests                        bb3b6b6 │   main                ✓ │
│   agent/add-tests 4 │ ●  v0.2  Show an error when …              86b3386 │   agent/add-tests    ↑1 │
│   agent/fix-login 3 │ …                                                  │   agent/fix-login ↑3 ↓2 │
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
- Below them, it lists every repository the user has added, until the user removes it ([decision 14](decisions/0014-the-sidebar-keeps-every-added-repository.md)). Each repository is a group: its name in bold, with a small triangle after the name that collapses or expands it. Under the name is the folder the repository is in, as in `~/git`, which tells apart clones with the same name and stays in view while the group is collapsed. Its label is the number of uncommitted files in all of its worktrees, in orange, while it's collapsed. On hover, buttons for Show in Finder, Open in Terminal and a menu with Remove from Sidebar take its place. A repository yaga can't find is dimmed, its label says so, and its menu can find it again or remove it.
- Each of the repository's worktrees has a row under it. The first line is the worktree's branch. The second is its folder and how long ago something in it changed, as in `fix-login · writing now`. The number of uncommitted files sits at the right in orange.
- Clicking a worktree row shows that worktree in the rest of the window. On hover, the count gives way to buttons that open the worktree in a new window or in Terminal, and its context menu has those and Show in Finder.

## The title row

The top row of the middle and right columns names what the window shows, as in `agents-demo / main`. Its right end holds buttons that apply to the whole window: the log of git commands yaga ran (later), and showing or hiding the refs panel. Dragging the empty part of the row moves the window, and double-clicking it does what the user chose in System Settings.

## Panels

Every section in the middle is a panel: a plain rectangle with a 40-point header, separated from its neighbors by thin lines rather than cards or shadows. A header reads from left to right, from what the panel shows to what you can do with it:

- The left side says what the panel shows: a title, a segmented switch, or a file's path.
- Any state the panel depends on comes next, as a chip with a small triangle, such as which branches the history includes or which two commits a diff compares.
- The panel's commands follow as icon buttons with tooltips. An icon button is a thin, dark glyph that gets a rounded gray square when the pointer is over it, like the Claude app's.
- A menu for more commands comes last. It lists every command the panel has, including the ones shown as buttons, with their keyboard shortcuts. Every command is also in the menu bar.
- When several things in a panel are selected, such as files in release 2, the header can switch to commands that act on the selection.
- Dragging the lines between panels resizes them.

## The history panel

The history panel fills the top of the middle column.

- A segmented switch, styled like the Claude app's switch between chat and code, chooses between **History** and **Changes**. The selected segment is raised in white on a gray track, and Changes shows how many uncommitted files the current worktree has. A segmented switch suits two or three views of the same panel. If more views join them, sub-tabs would scale better.
- The right side of its header shows which branches the history includes, a switch between topological order and date order (decision 12), and a menu for more commands.
- **History** lists commits with the graph, then the commit's refs as colored badges, its subject, author, date and short hash. The current branch is green with a checkmark, local branches are blue, remote branches are purple, and tags are orange.
- **Changes** lists the current worktree's uncommitted files, each with a status letter, its name and its folder. [Options we're keeping open](#options-were-keeping-open) has other ways to show them.

## The commit and diff panels

Two panels sit under the history panel.

- **The commit panel** shows the selected commit: its subject and message, author, date and parents, and the files it changed with the lines added and removed in each. Its header shows the short hash and a button that copies the full hash.
- **The diff panel** shows the selected file's changes as a unified diff without wrapping, with backgrounds for added lines, removed lines and hunk headers. Its header shows the file's path, with the folders in gray and the file name in full color, and buttons for finding text, opening the file in an editor, and more. Line numbers and highlighted changed words come with the TextKit 1 view (decision 9).
- In **Changes**, the commit panel is hidden and the diff panel takes the full width.

## The refs panel

The refs panel is on the right. It's a shade darker than the panels, like the sidebar. It's the inspector macOS provides, and the button at the right end of the title row hides it.

- Its header has the title **Refs**, a button that sorts by name or by date, and a menu for more commands. A filter field below the header narrows every section at once.
- Its sections are **Branches**, **Remotes**, **Tags** and **Stashes**. A section's header shows its title with a small triangle after it, and clicking the header collapses or expands the section. The header shows how many items the section has, and on hover it shows the section's commands instead, such as creating a branch or tag in release 2.
- A branch row shows the branch's name. Its second line says which worktree has it checked out and how far it is ahead of or behind the branch it's compared with, as in `in fix-login · 3 ahead, 2 behind main`, and the same counts sit at the right as arrows. The branch checked out in the window's worktree has a checkmark. On hover, the row shows buttons that hide the branch from history and review it against its base.
- A remote shows its URL, with its branches under it. A tag shows the subject of the commit it points to. A stash shows its message and when it was made.

## Colors and type

- Surfaces are plain, with thin gray lines between sections. The sidebar and the refs panel are a shade darker. Dark mode keeps the same structure in dark grays.
- Selection is a soft gray fill, not the accent color. The accent color is kept for the graph.
- Text uses the system font at 12.5 to 13 points. The sidebar's rows use 14 points, with 13 for a second line and for shortcuts, as the Claude app's sidebar does. Hashes and diffs use the monospaced system font.

## Options we're keeping open

We sketched several ways to show history and uncommitted changes, and they're worth revisiting once the real views exist. The wireframe above uses the History and Changes switch for now.

- **Uncommitted changes as the first row of history.** The working tree appears above `HEAD` as a hollow node, the way Fork, GitKraken and Tower draw it. Selecting it lists unstaged, untracked and staged files in one list with a header for each group, in the same rows a commit's files use, so the History and Changes switch goes away. A file with both staged and unstaged changes appears in both groups, and a switch in the diff panel's header chooses which diff it shows. This is the favorite so far.
- **Changes as its own view**, the way Fork does it: unstaged files on top, staged files below, and in release 2 the commit message under them, so files move down toward the commit. Each list is a panel with its own title, count and commands. This earns its place once staging arrives in release 2.
- **One review pane for every set of changes**, like the diff panes in the Claude and ChatGPT apps. Chips in the header choose what to compare, such as uncommitted changes, a branch against its base, one commit or a stash, and show the lines added and removed. Every file is a collapsible block in one scrolling diff, with a check for marking it viewed, and a tree of files on the right jumps between them. This could be where branch review and stashes appear. Showing many files in one scrolling diff needs a prototype first, because decision 9's text view shows one file at a time.
- **Tabs in a panel's header**, from the ChatGPT app's pane for changes, so that several comparisons can stay open at once.

[Decision 13](decisions/0013-repositories-in-a-sidebar.md) lists the other places we sketched for repositories.

## Still open

- How repositories are reordered in the sidebar: by dragging, or with commands that move one up or down.
- How often the sidebar updates the uncommitted counts of repositories that aren't showing.
- What collapses first when the window gets narrow. Decision 13 expects the refs panel to go first.
- What clicking a branch does when a worktree has it checked out: select its tip in history, or switch the window to that worktree.
- Which branch each branch is compared with in the refs panel: its upstream, or the repository's main branch.
- What Command-1 to Command-9 and Control-Tab do now that there are no tabs, such as selecting repositories in the sidebar or switching between History and Changes.
- Where branch review, file history and the contents of a stash appear. The review pane above is one answer.
- How wide the commit panel is by default, and whether it can be hidden.
