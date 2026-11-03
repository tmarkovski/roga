# Main window

This is the rough wireframe of yaga's main window for release 1. It settles the overall layout. Details will change as we build the real views.

The layout follows the Claude and ChatGPT apps. A sidebar on the left has a rail for picking an organization and lists its repositories with their worktrees under them, the selected worktree's history and diffs fill the middle, and a panel on the right lists the repository's branches, remotes, tags and stashes. The sections in the middle are plain rectangles, and the ones under history have their own headers. [Decision 13](decisions/0013-repositories-in-a-sidebar.md) explains why repositories moved out of tabs and into the sidebar, and [decision 16](decisions/0016-a-rail-of-organizations-in-the-sidebar.md) explains the rail and what folds. The [main window preview](../prototypes/main-window/README.md) still shows the earlier layout, with tabs on top and worktrees in a navigator on the right.

```text
┌──────────────────────────────┬──────────────────────────────────────────────────┬────────────────────────┐
│ ● ● ●  ◧                     │ agents-demo  main · 128 commits              ≡ ◨ │               ⌕  ⇅  ⋯  │
├──────┬───────────────────────┼──────────────────────────────────────────────────┼────────────────────────┤
│ [▣]  │ All repositories  19  │ ○  3 uncommitted files                           │ Branches ▾           4 │
│ AC   │ api ▾           7  ⧉ 4│ ●  agent/fix-login  Add login tests      48ba644 │   main               ✓ │
│ NO   │   agent/add-tests    4│ ●  ✓ main  Update the changelog          5405371 │   agent/add-tests   ↑1 │
│ TM   │   agent/fix-login    3│ ●  Add parser tests                      bb3b6b6 │   agent/fix-login ↑3 ↓2│
│ …    │   2 quiet worktrees ▸ │ ●  v0.2  Show an error when …            86b3386 │ Remotes ▾            1 │
│      │ auth  release/2.3     ├───────────────────┬──────────────────────────────┤   origin               │
│      │ billing              1│ Commit 5405371  ⧉ │ CHANGELOG.md     ⌕  ↗  ⋯     │ Tags ▾               2 │
│      │ docs                  ├───────────────────┼──────────────────────────────┤   v0.2                 │
│      │ infra                 │ Update changelog  │ @@ -1,6 +1,10 @@             │   v0.1                 │
│  +   │ web ▸          2  ⧉ 2 │ CHANGELOG.md +4 −0│   # Changelog                │ Stashes              0 │
│      │ yaga ▸               3│                   │ + ## 0.3                     │                        │
└──────┴───────────────────────┴───────────────────┴──────────────────────────────┴────────────────────────┘
```

## The sidebar

The sidebar runs the full height of the window on the left, with the traffic lights at its top. It's 312 points wide by default: the 56-point rail and the list beside it. It's a shade darker than the panels, and a thin gray line separates it from them, from the top of the window to the bottom, as in the Claude app. It's the sidebar macOS provides, so the button next to the traffic lights, the View menu and the usual shortcut all hide it. That button is a plain icon that gets a gray square on hover, like the icon buttons in panel headers, rather than the glass button macOS draws. It stays next to the traffic lights while the sidebar is hidden.

### The rail

The rail picks which repositories the list shows ([decision 16](decisions/0016-a-rail-of-organizations-in-the-sidebar.md)). A thin line separates it from the list, starting under the traffic lights.

- From the top, it has **All**, then each organization from A to Z, then **Other** when it has any repositories. An organization shows two letters from its name, and its tooltip has the whole name. A button at the bottom adds repositories. Items are 38 points square with 9-point corners, and the selected one fills with gray.
- An organization is the owner in a repository's `origin` URL, with at least two repositories listed. Other has the rest.
- Clicking an organization shows the worktree last shown there, or the main worktree of its first repository. Clicking All keeps the window on what it shows. Each window remembers its own organization, and the last worktree in each.
- View > All Repositories and the organizations after it have the shortcuts Command-1 to Command-9. View > Hide Organizations, Control-Command-O, hides the rail, which leaves All, and the button for adding repositories moves to the top of the list.

### The list

The list starts with the name of what the rail picked, in bold, and how many repositories it has. Every row in the list fills with gray while the pointer is over it, and the selected worktree's row keeps a slightly darker gray. The fill has 8-point corners and leaves 8 points on each side. Rows are 32 points tall with 2 points between them, as in the Claude app. A row's top right corner shows a label, which gives way to the row's commands on hover: 24-point buttons 4 points from the top and right edges. The sidebar draws these rows itself, because a macOS sidebar list can't, so it also handles the arrow keys: up and down move between the worktrees showing, and right and left show and hide the linked worktrees of the selected one's repository.

- A repository's row is its main worktree. Clicking it selects that worktree. Its name is bold while any of its worktrees has uncommitted files. A small triangle after the name shows or hides its linked worktrees, and a repository without any has no triangle. After the triangle, in gray, comes the main worktree's branch unless it's `main` or `master`, or when two listed repositories have the same name, the folder it's in, as in `~/git`.
- Its label is the number of uncommitted files, in orange, then the number of linked worktrees, after an icon of two overlapping squares. The number of uncommitted files is the main worktree's while the repository is expanded, and all of its worktrees' while it's collapsed. On hover, buttons for Show in Finder, Open in Terminal and a menu with those, Open in New Window and Remove from Sidebar take the label's place. A repository yaga can't find is dimmed, its label says so, its menu can find it again or remove it, and selecting it shows the same commands in the middle of the window.
- Each linked worktree has a row under its repository, indented, with its branch and its number of uncommitted files in orange. Its tooltip has its folder. On hover, the count gives way to buttons that open the worktree in a new window or in Terminal, and its context menu has those and Show in Finder.
- The selected worktree always shows, even when its repository is collapsed. Otherwise, worktrees with uncommitted files show, and two or more quiet ones fold into a row such as **3 quiet worktrees**, which shows them and then says **Show fewer**. A single quiet worktree just shows.
- Repositories go from A to Z ([decision 16](decisions/0016-a-rail-of-organizations-in-the-sidebar.md)), and a new one starts collapsed. The list keeps every repository the user has added until they remove it ([decision 14](decisions/0014-the-sidebar-keeps-every-added-repository.md)).
- With All selected, the list has every repository from A to Z, with no headers, and only worktrees fold.
- With Other selected, the list has **Other owners**, with repositories named as `owner/name`, and **No remote**.

### Adding repositories

The button on the rail opens a popover, titled **Add to acme** with an organization selected and **Add Repositories** otherwise.

- It lists the clones it finds in the folders the user has added repositories from, one level deep, leaving out what the sidebar lists. With an organization selected, it lists the ones with that owner, and with Other selected, the ones that don't belong to an organization on the rail. Each row has a checkbox, the clone's name, its folder and when it was last used, which is when its index last changed, and the latest come first.
- A field at the top filters by name. The down arrow goes from it to the rows, where the up and down arrows move, Space checks a row and Return adds what's checked, or else the row the keyboard is on.
- **Look in Another Folder…** lists the clones in a folder the user picks, or the folder itself if it's a clone, which starts checked. **Add Selected** adds them to the sidebar and shows the first.

File > Open still asks for a folder and adds its repository, from anywhere.

## The title row

The top row of the middle column is 40 points tall, like a panel's header, and names what the window shows on one line: the repository, then in gray the branch and how many commits history has, as in `main · 128 commits`. They're the same size, and they truncate to leave room for the commands. A thin line runs along the bottom of the row, from the sidebar to the edge of the window, across the refs panel. The right end of the row holds the commands for history, then the button that shows or hides the refs panel, which moves to the edge of the window while the panel is hidden. It'll also hold the log of git commands yaga ran. Dragging the empty part of the row moves the window, and double-clicking it does what the user chose in System Settings.

## Panels

The sections under history are panels: plain rectangles with a 40-point header, separated from their neighbors by thin lines rather than cards or shadows. History has no header, because the title row says what it would. A header reads from left to right, from what the panel shows to what you can do with it:

- The left side says what the panel shows: a title or a file's path.
- Any state the panel depends on comes next, as a chip with a small triangle, such as which branches the history includes or which two commits a diff compares.
- The panel's commands follow as icon buttons with tooltips. An icon button is a thin, dark glyph that gets a rounded gray square when the pointer is over it, like the Claude app's.
- A menu for more commands comes last. It lists every command the panel has, including the ones shown as buttons, with their keyboard shortcuts. Every command is also in the menu bar.
- When several things in a panel are selected, such as files in release 2, the header can switch to commands that act on the selection.
- Dragging the lines between panels resizes them. The height and width of the commit panel are one setting each for every window. The panels above and below the line stay at least 100 points tall, and those beside it at least 180 points wide.

## The history panel

The history panel fills the top of the middle column.

- Its commands are at the right end of the title row: a switch between topological order and date order (decision 12), and later which branches the history includes and a menu for more commands.
- It lists commits with the graph, then the commit's refs as colored badges, its subject, author, date and short hash. The current branch is green with a checkmark, local branches are blue, remote branches are purple, and tags are orange.
- A badge for a branch other than the current one gets a border when the pointer is over it, and double-clicking it checks the branch out. A local branch is switched to. A remote branch goes through the local branch of the same name: it's created to track the remote branch, or if it's there already, switched to as it is, even if it's behind. A branch that another worktree has checked out shows that worktree in the window instead, because git won't check a branch out twice. Either way, the commit of the branch you end up on is selected, rather than whatever that worktree had selected. Uncommitted changes come along when git can carry them. When it can't, or refuses for another reason, an alert shows what git said and nothing changes. A checkout that takes more than half a second says so in the title row, before history's commands, and another double-click does nothing until it finishes. There's no confirmation, since nothing gets lost.
- While the worktree has uncommitted files, a row for them comes first, with a hollow dot and how many files there are ([decision 15](decisions/0015-uncommitted-changes-as-a-row-in-history.md)). A line runs from it to the commit `HEAD` points to, past any commits above `HEAD`, and past 100 rows it's cut into two arrows, as other long lines are. A worktree with no changes has no row. The row appears, goes and updates when yaga becomes the active app, when the window shows the worktree again, and on View > Reload. A ref that moved loads history again at the same moments.
- When history takes more than a second to load, the panel says under the spinner why, if it's because the repository has no commit-graph file that yaga can use, and what yaga is doing about it ([decision 6](decisions/0006-keep-the-commit-graph-up-to-date.md)). Once history shows, a repository with at least 50,000 commits keeps a note in the title row, before history's commands: **Writing commit-graph file…** while git writes it, or **Opens slowly** with a tortoise when yaga won't or can't write one. The note's tooltip gives the reason.

## The commit and diff panels

Two panels sit under the history panel.

- **The commit panel** shows the selected commit: its subject and message, author, date and parents, and the files it changed with the lines added and removed in each. Its header shows the short hash and a button that copies the full hash, which Edit > Copy Commit Hash and Shift-Command-C do too. It shows the committer as well when that differs from the author. Clicking a parent's hash selects the parent in history. A merge lists what changed compared with its first parent, and says so. With nothing selected, which is how a worktree opens, the panel asks you to select a commit. Selecting a commit selects its first file. Clicking a file selects it, and then the up and down arrows move through the list. View > Next File and Previous File, Option-Command-Down Arrow and Option-Command-Up Arrow, do the same while the keyboard is in history.
- **The diff panel** shows the selected file's changes as a unified diff without wrapping, with backgrounds for added lines, removed lines and hunk headers. Within changed lines, a stronger background marks the words that differ from the other side, and spaces that differ around words that don't, such as extra indentation. A line that has little in common with the other side shows no marks, because its background says enough. A strip on the left has each line's numbers in the old and new file and a bar beside each changed line, solid for an added line and striped for a removed one, so that they differ without relying on color. The strip stays put as the text scrolls sideways, and a selection doesn't copy it. Its header shows the file's path, with the folders in gray and the file name in full color, then where a moved file came from and how its mode changed, and a button for finding text, which Edit > Find in Diff and Command-F do too. The button opens a box beside it, which fills the room up to 320 points wide. The path stays to its left if at least 120 points are left for it, and otherwise goes away until the box closes. The button looks pressed while the box is open. Pressing it again or Escape closes the box, selects the match the search was at and puts the keyboard in the text. The box says which match the search is at and how many there are, and every match is marked, ignoring case. Return and the button with the down arrow go to the next match, and Shift-Return and the button with the up arrow go to the previous one, as do Edit > Find Next and Find Previous with Command-G and Shift-Command-G. The ✕ in the box clears the text and leaves the box open. The box stays open from one file to the next, and looks in each. A file with no lines to compare, such as a binary file, gets a sentence saying what changed. The header will have buttons for opening the file in an editor, and more.
- **With the row for uncommitted changes selected**, a panel titled Uncommitted Changes takes the commit panel's place. It lists the files under the headings Conflicts, Unstaged, Untracked and Staged, each with how many files it has and how many lines they change, in the same rows as a commit's files. A file with both staged and unstaged changes is listed under both, and each row selects its own diff. An untracked file shows no line counts. The diff panel's header says which heading the file is under, and a conflicted file's diff compares the worktree with `HEAD`, so its conflict markers show as added lines. Selecting the row selects the first file. When the files are read again, the selected file stays selected and its text stays at the same place, even if the file changed. Once it has no changes, the first file is selected, and once there are no uncommitted files, nothing is.

## The refs panel

The refs panel runs the full height of the window on the right, with a thin line between it and the middle from the top of the window to the bottom, like the sidebar's. It has the same background as the panels. It's a plain panel of ours rather than the inspector macOS provides, which animated by itself, stuttered, lost a dragged width and made the window wider ([issue 7](https://github.com/tmarkovski/yaga/issues/7)). The button at the right end of the title row hides it, as View > Hide Refs and Control-Command-I do. It shows and hides at once. It's 288 points wide and can be dragged up to 400, which is one setting for every window, and it keeps that width while it's hidden.

As the window gets narrower, the panel narrows to keep 400 points for the middle, down to 288. After that it gives way, and its button and menu command are disabled until there's room. It comes back by itself when the window is wide enough again, unless the user had closed it. Decision 13 expected the panel to be what gives way first.

- Its top row is the rest of the title row, and has buttons for filtering and for sorting by name or by date, and a menu with every command the panel has. They're items in the window's toolbar, whose empty parts still move the window.
- The button for filtering opens a field in the same row, which fills the room up to the button, and the button looks pressed while the field is open. View > Filter Refs and Option-Command-F open it too, showing the panel first if it's hidden. The field narrows every section at once, by the names of branches, remotes and tags and the messages of stashes, and it opens any section that's collapsed. The down arrow goes from the field to the first row. The ✕ in the field clears the text and leaves the field open. Pressing the button again or Escape clears the filter and closes the field.
- Its sections are **Branches**, **Remotes**, **Tags** and **Stashes**. A section's header shows its title with a small triangle after it, and clicking the header collapses or expands the section, which is one setting for every repository. A section with nothing in it has no triangle and nothing to click, and shows only its title and `0`. The header shows how many items the section has, stays in view while its rows scroll, and on hover it will show the section's commands, such as creating a branch or tag in release 2.
- Clicking a branch, remote branch or tag selects its commit in history, whichever worktree has it checked out. After that the up and down arrows move through the rows, skipping remotes, stashes and anything else with no commit to select.
- A branch row shows the branch's name. Its second line says which worktree has it checked out and how far it is ahead of or behind the branch it's compared with, as in `in fix-login · 3 ahead, 2 behind main`, or when it last changed if neither applies, and the same counts sit beside the name as arrows. A branch is compared with its upstream, or without one, with the repository's main branch: the one `origin/HEAD` names, or a local `main` or `master`. The branch checked out in the window's worktree comes first and has a checkmark. On hover, a branch that another worktree has checked out shows a button that switches the window to that worktree and selects the branch's commit there. The buttons that hide a branch from history and review it against its base come with those features.
- A remote shows its address, without the user name or password in its URL, with its branches under it and each one's date. A remote that has branches left but isn't configured any more says so. A tag shows the subject of the commit it points to. A stash shows its message, what git calls it and when it was made, and clicking one doesn't do anything until the panels can show what's in it.
- By name, branches and remote branches go from A to Z and tags go from the latest version to the oldest, and numbers in names count as numbers, so `v0.10` is newer than `v0.9`. By date, they all go from the latest to the oldest. Stashes keep git's order, which is already that.

## Colors and type

- Surfaces are plain, with thin gray lines between sections. The sidebar is a shade darker. Dark mode keeps the same structure in dark grays.
- Selection is a soft gray fill, not the accent color. The accent color is kept for the graph.
- Text uses the system font at 12.5 to 13 points. The sidebar's rows use 14 points, with 13 for a second line and for shortcuts, as the Claude app's sidebar does. Hashes and diffs use the monospaced system font.

## Options we're keeping open

We sketched several ways to show uncommitted changes. [Decision 15](decisions/0015-uncommitted-changes-as-a-row-in-history.md) chose the row at the top of history for release 1, and these others are worth revisiting now that the real views exist.

- **Changes as its own view**, the way Fork does it: unstaged files on top, staged files below, and in release 2 the commit message under them, so files move down toward the commit. Each list is a panel with its own title, count and commands. This earns its place once staging arrives in release 2.
- **One review pane for every set of changes**, like the diff panes in the Claude and ChatGPT apps. Chips in the header choose what to compare, such as uncommitted changes, a branch against its base, one commit or a stash, and show the lines added and removed. Every file is a collapsible block in one scrolling diff, with a check for marking it viewed, and a tree of files on the right jumps between them. This could be where branch review and stashes appear. Showing many files in one scrolling diff needs a prototype first, because decision 9's text view shows one file at a time.
- **Tabs in a panel's header**, from the ChatGPT app's pane for changes, so that several comparisons can stay open at once.

[Decision 13](decisions/0013-repositories-in-a-sidebar.md) lists the other places we sketched for repositories.

## Still open

- Whether the rail's organizations can be dragged into another order, and whether they show avatars, which takes the network.
- How often the sidebar updates the uncommitted counts of repositories that aren't showing.
- What gives way after the refs panel when the window gets narrow, such as a sidebar someone dragged wide.
- What Control-Tab does now that there are no tabs, such as going back to the worktree shown before.
- Which keyboard shortcut goes to the row for uncommitted changes, which can be scrolled out of view.
- Whether a worktree with uncommitted changes opens with their row selected.
- Whether untracked files show how many lines they have, which takes reading each one.
- Where branch review, file history and the contents of a stash appear. The review pane above is one answer.
- How wide the commit panel is by default, and whether it can be hidden.
- Whether a worktree opens with `HEAD` selected, rather than with nothing selected.
- Whether going to another commit should stay on the same file, if the commit changed it, rather than selecting the first one.
- Whether a commit's long message should push its files down, now that the files are how you get around the diff.
- Whether the diff's tabs should be as wide as they are in a terminal, which is 8 columns.
