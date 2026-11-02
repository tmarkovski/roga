# 15. Show uncommitted changes as a row at the top of history

Accepted on 2026-11-02. This chooses among the ways to show uncommitted changes that the [main window](../main-window.md#options-were-keeping-open) kept open.

## Context

Release 1 is for someone who keeps yaga next to a terminal to review what they and their agents have changed, and most of that work is uncommitted while they're looking at it. The wireframe drew a switch between History and Changes, which hides the commit panel and needs a second layout. The favorite among the other sketches was a row for the working tree above `HEAD`, the way Fork, GitKraken and Tower draw it.

History shows every branch, remote branch and tag, so `HEAD` isn't always the first row. In a repository where agents work on branches, it's often lower down.

## Decision

- While a worktree has uncommitted files, a row for them comes before the first commit. It has a hollow dot and says how many files there are. A worktree with no changes has no row, and there's no switch between History and Changes.
- Selecting the row shows its files where a commit's files go, in the same rows, under the headings Conflicts, Unstaged, Untracked and Staged. A file with both staged and unstaged changes is listed under both, and each row selects its own diff, so the diff panel needs no switch of its own.
- A line runs from the row to the commit `HEAD` points to, straight down in the first column that's free of every row it crosses, and it curves into `HEAD`'s dot. Past 100 rows it's cut into two arrows, as other long lines are. It's drawn over the graph's layout rather than being part of it. A worktree can go from clean to changed at any moment, and laying out all of Linux again would take seconds.
- `git status` decides which files have changes. `git diff-files` also lists a file that was only touched, because nothing has told the index otherwise, and yaga doesn't write the index. `diff-index` and `diff-files` then count lines and print patches, because they ignore settings such as `diff.context`, as the `diff-tree` that shows commits does. An untracked file's patch comes from `git diff --no-index` against `/dev/null`.
- Every untracked file is listed, rather than the folders that hold them, unless the user set `status.showUntrackedFiles` to `no`. Someone who keeps their home folder in a repository relies on that setting, because git would otherwise go through every file they have.

## Consequences

- The commit panel and the diff panel work the same way for commits and for uncommitted changes, so moving between them is one arrow key.
- The row is at the top of history, so it's out of view once the user scrolls down. The sidebar's count stays in view, and a keyboard shortcut for going to the row is still to be chosen.
- The rows below it move down one when it appears, and up one when it goes. On a repository the size of Linux, the first screen of history can show before status finishes, and the row then arrives a moment later.
- The line can sit to the right of the branches it passes, instead of in `HEAD`'s column. Laying it out with the graph would look tidier and is what the other apps do, but it would mean laying out history again whenever a worktree goes from clean to changed.
- An untracked file shows no line counts, because counting them takes reading each file. Its diff shows them once it's selected.
- A conflicted file's diff compares the worktree with `HEAD`, which shows its conflict markers as added lines. `git diff-files` would print a combined diff, which `PatchParser` doesn't read and release 1 has no way to show.
- Staging in release 2 may want files to move between groups, which is what the option of showing changes as a view of their own was for. That can still be added next to the row.
