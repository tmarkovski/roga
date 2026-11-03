# 17. Show a repository's worktrees with a line, and collapse them into one row

Accepted on 2026-11-03. This replaces what [decision 16](0016-a-rail-of-organizations-in-the-sidebar.md) says about quiet worktrees folding, and how a collapsed repository looks.

## Context

Decision 16 gave a repository's linked worktrees two ways to hide. A triangle collapsed all of them, and inside an expanded repository, two or more worktrees without uncommitted files folded into a row such as **3 quiet worktrees**. That row opened to show them and then said **Show fewer**. So there were three states to understand, and an expanded repository could still be hiding worktrees. A collapsed repository gave no sign of its worktrees under it, apart from a count in its label. Indenting was all that tied a worktree's row to its repository.

The Claude app's sidebar shows the same relationship between a session and the sessions nested under it, and it reads better: a line ties them together, and a collapsed session has a row under it that says how many it's hiding.

## Decision

**One line ties the rows under a repository to it.** It runs down from the repository's row past each row under it, and turns around a rounded corner into the last one. Rows in between have no corner of their own.

**A repository is either expanded or collapsed.**

- An expanded repository shows every linked worktree. Nothing folds inside it, so the rows for quiet worktrees and **Show fewer** are gone.
- A collapsed repository has one row under it, on the same line, such as **3 worktrees**, with how many uncommitted files those worktrees have in orange. Clicking it expands the repository.
- The selected worktree always shows, as before. The row for the others then says **2 more worktrees**, and there's no such row if it's the only one.
- The triangle after the name, and the right and left arrows, still expand and collapse a repository, and the choice is still saved. A new repository still starts collapsed.

**A repository's row counts only itself.** Its orange number is always the main worktree's uncommitted files, because the rows under it count theirs in both states. The number of linked worktrees leaves its label, since the rows under it say the same thing.

**Commands that are rarely needed go in a menu.** On hover, a repository's row shows only a button for its menu, and a worktree's row shows Open in New Window and a button for its menu. Show in Finder and Open in Terminal are in those menus, so a row has room for its name. Worktree rows didn't have that button before, only a context menu.

## Consequences

- A collapsed repository with linked worktrees takes two rows rather than one. A repository without any still takes one.
- An expanded repository with many worktrees is as long as it has worktrees, however quiet they are, until it's collapsed. If that gets in the way, folding quiet worktrees is the thing to bring back.
- A worktree where an agent has committed everything no longer folds away by itself, so it's in plain sight in an expanded repository. Until yaga knows about agents, a collapsed repository's row is the only sign of what's inside it.
- Showing a worktree in Finder or Terminal takes one more click.
- `repositories.json` doesn't change. It saves whether each repository is expanded, as it did.
