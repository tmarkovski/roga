# 81. Stash in one click, and put stashes back from their menu

Accepted on 2026-11-15. This builds on [decision 56](0056-the-panels-show-a-run-of-commits-two-commits-a-branch-or-a-stash.md), which shows a stash in the panels, and borrows from [decision 39](0039-discard-with-undo-and-ask-only-for-many.md), which uses Undo rather than a question, and [decision 59](0059-set-aside-changes-in-the-way-and-put-them-back.md), which puts Roga's own stashes back.

## Context

The refs panel listed stashes, and clicking one showed what it held, but that was all Roga could do with them. A stash's row had no menu and its panel had no buttons, so putting one back or deleting it meant going to the command line, and nothing in the window made a stash either. The rows also started every message with git's `On agent/fix-login:`, which pushed the part someone wrote out of view.

We sketched three ways to stash on the Stashes page of the design canvas, each drawn with the same worktree: `agent/fix-login` in `agents-demo`, with three uncommitted files and two stashes, one of which conflicts when it comes back.

- **A: One click.** A button in the Uncommitted Changes header and a row in history's menu stash everything at once, and Undo in the title row takes it back. This is the one we chose.
- **B: A sheet that asks for a name first,** with a switch for untracked files and the command, the way Fork and Sourcetree do it. It costs a sheet every time, for a name that most stashes don't need.
- **C: A Stash button beside Commit,** which names the stash after whatever is typed as the commit message. The button only exists while the uncommitted row is selected, so it would work better added to A later than chosen instead of it.

## Decision

**Stashing takes one click and doesn't ask.** The Uncommitted Changes header has a Stash Changes button with Lucide's `archive` and an arrow, history's row for uncommitted changes has **Stash changes** above **Discard all changes…**, and **Changes > Stash Changes** has Shift-Command-S. Each runs `git stash push --include-untracked`, so that staged, unstaged and untracked files all go and the worktree is left clean. git leaves a repository inside the worktree where it is, such as an agent's worktree. Stashing waits while a worktree has conflicts or is partway through something, since git can't stash a conflict.

**The stash is named after its files,** as in `SessionStore.swift, TokenRefresher.swift and scratch.md`, or the first two and how many more. That says more in the list than git's `WIP on agent/fix-login: 4be21c0 Log failed sign-ins`.

**The new stash is selected, and the title row says `Stashed 3 files` with Undo for 8 seconds,** as it does for a commit and a discard. Selecting it shows exactly what went in. Undo puts it back.

**A stash's row leaves out the branch git puts at the start of its message,** and names the branch on its second line instead, as in `stash@{0} · agent/fix-login · 2 hours ago`. Its panel names the branch too. A message that doesn't start the way git's do is shown as it is.

**A stash's menu uses plain words rather than git's pop and apply:**

| Item | What runs |
| --- | --- |
| Put back | `git stash pop --index`, which deletes the stash once it's back |
| Put back and keep the stash | `git stash apply --index` |
| New branch from stash… | `git stash branch`, from the New Branch popover, without In a new worktree |
| Copy message | Copies the message without the branch |
| Delete | `git stash drop`, with Undo |

A selected stash's panel has **Put Back** in its header, in orange, since it's usually what comes next. Each item finds the stash by its commit rather than by `stash@{n}`, because an agent can stash or drop one meanwhile, which moves the others.

**What was staged comes back staged, unless something else is staged already.** git 2.52 refuses `--index` when the stash has staged files and the index has other changes, and on the way out it unstages them, though their contents stay. So Roga only asks for `--index` when nothing is staged. Otherwise the stash's files all come back unstaged, the user's staging stays as it was, and the title row says `Put back 3 files · its staging wasn't kept`.

**Delete doesn't ask, and gets Undo instead,** because git keeps the stash's commit until it prunes what nothing points to, which takes weeks. Undo runs `git stash store` with the same message, which lists it again at the top, since that's the only place git can add one.

**When putting a stash back stops on a conflict,** a dialog says so, as decision 59's does for Roga's own stashes, with **Resolve**, which shows the conflicts, and **Undo**. git keeps the stash in the list then, so nothing is lost. As in decision 59, the files that came back cleanly go back to being unstaged unless they were staged before or in the stash. Undo puts the files the stash had back to what was staged before, and removes the untracked ones it brought. That leaves everything else alone, and it's safe because git won't put a stash back over a file with unstaged changes or over an untracked file.

## Consequences

- Stashing part of the changes, such as one file or one heading, isn't here yet. git can do it with `git stash push -- <paths>`, and a file's or a heading's menu is where it would go.
- Put back and Put back and keep the stash have no Undo. The changes are back on disk, and stashing them again is one click.
- A stash that's listed again after Undo is at the top of the list, so its name changes, as in `stash@{1}` becoming `stash@{0}`.
- When something is staged, a stash's staging is lost on the way back. Someone who needs it can unstage first, or use the command line.
- Undoing a put back that stopped on a conflict can't bring back a file's unstaged edits if git ever merges into one. git refused to in every case we tried.
