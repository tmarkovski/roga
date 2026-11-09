# 65. One menu for a commit or a branch

Accepted on 2026-11-09. This brings back the submenus that [decision 33](0033-one-row-in-a-menu-and-the-choice-in-the-dialog.md) removed from `RefMenu`, for a different kind of row, and it replaces what [decision 44](0044-revert-a-commit-from-its-menu-in-history.md) and [decision 38](0038-one-delete-on-a-commit-with-its-branches-in-the-dialog.md) say a commit's menu holds, while keeping how Revert and Delete work.

## Context

Right-clicking a commit offered Replay History, Revert and Delete. Going to a commit or a branch took a double-click, and merging, rebasing, cherry-picking, or starting a branch or a tag on an older commit took the command line.

We read what other clients offer from their own sources, which are GitHub Desktop's commit and branch menus, SourceGit's strings for its menus, and GitLens's graph items. All of them offer checking out a commit, resetting to it, reverting it and cherry-picking it. SourceGit and GitLens also merge and rebase, and offer pull and push for each branch. Interactive rebase, squash, reword and drop are there too, as are saving a patch and opening a commit on GitHub.

## Decision

**The menu goes by what was clicked.** A badge acts on its own ref. Anywhere else on a row with a branch, it acts on the current branch if that's on the row and otherwise on the first local branch, as double-clicking does ([decision 37](0037-double-click-a-commit-to-go-to-it.md)). A row with no branch acts on the commit. A tag's badge acts on its commit and adds the tag's name to Copy. The refs panel's branches and remote branches build the same menu.

**The rows, in groups:**

| Group | Another branch | The current branch | A commit |
| --- | --- | --- | --- |
| Going there and bringing it in | Check Out, then Fast-Forward main to it, or Merge… and Rebase…, then Cherry-Pick | Pull, Push, Fetch | Check Out This Commit, Cherry-Pick |
| Changing the branch | Reset main to Here…, Revert… | | Reset main to Here…, Revert… |
| More | Create, Remote, Copy, Review, Replay | Create, Copy, Review, Replay | Create, Copy |
| | Delete… | | |

**Only three things are submenus: Create, Remote and Copy**, because each holds commands that are different from one another. Decision 33 still says that commands that differ only in how far they go share one row and put the choice in the dialog. So Reset is one row, and Soft, Mixed, Keep and Hard are in its dialog.

**What can't apply isn't offered.** A branch that `HEAD` already has offers no merge, rebase or cherry-pick. One that's only ahead of `HEAD` offers a fast-forward in place of merging and rebasing, which would come to the same thing. This goes by how each branch stands against `HEAD`, which `git for-each-ref` reads with `%(ahead-behind:<commit>)` whenever history loads, because a menu has to open without waiting for git. Until that's been read, the menu offers both, and the dialogs say what's what. For a commit with no branch, it walks back from `HEAD` as far as 20,000 commits, stopping at the commit's date. Past that it offers the cherry-pick, and the dialog says if `HEAD` has it.

**Pull, Push and Fetch are on the current branch's row**, where they mean what the title row means by them. On another commit's row they wouldn't act on what was clicked. Another local branch can push, and fast-forward from its upstream with `git fetch . <upstream>:<branch>`, under Remote.

**Merge and Rebase ask, and a fast-forward doesn't.** A fast-forward can't lose or rewrite anything, so it runs straight away. A merge says what comes in. A rebase says which commits get new hashes, and whether any of them are on the upstream, which would make the next push a force push. Both refuse to run if `HEAD` has moved while the dialog was open, because an agent may have committed.

**Cherry-Pick runs straight away unless there's something to say:** a merge, which it applies against its first parent with `-m 1`, or a commit `HEAD` already has, where Return doesn't press the button because that's probably a slip. A commit that turns out to change nothing is skipped with `git cherry-pick --skip`, so the worktree isn't left partway through an empty commit.

**A cherry-pick that stops is a state of its own**, like a revert, with `Cherry-picking a1b2c3d4 · 2 conflicts` in the title row and an abort in its menu. A rebase that stops also leaves a `CHERRY_PICK_HEAD`, so that's checked after the rebase's folders. The commit box finishes one with **Commit Cherry-Pick**, and git keeps the original author.

**Resetting offers what fits.** Going back along the branch offers all four ways. Going across to another line offers only Keep and Discard, because staged or unstaged changes there would also undo whatever is on the other side, as decision 37 says of Keep changes. Keep is what's picked to start with. The button is red when something can't be brought back, and outlined in red when commits go but what they changed stays.

**Uncommitted changes in the way go aside and come back** for merging, fast-forwarding, rebasing and cherry-picking, as they do for a pull ([decision 59](0059-set-aside-changes-in-the-way-and-put-them-back.md)).

**Left out on purpose.** Interactive rebase, squash, reword and drop belong to the visual editor planned for release 3, and a menu of them would compete with it. Anything specific to GitHub needs its own decision.

## Consequences

- A row can be 14 or so rows tall, against three before. Grouping keeps the ones used most at the top.
- Rows that name both branches can be long, and are cut short in the middle like any other.
- A new branch or tag from the menu opens its popover at the New Branch button in the title row, which is where New Worktree… from the sidebar already opens it, rather than next to the row.
- One more `git for-each-ref` runs each time history loads.
- These commands aren't in the menu bar yet, so they have no keyboard shortcuts.
