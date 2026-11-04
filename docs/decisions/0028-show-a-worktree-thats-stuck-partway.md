# 28. Show a worktree that's stuck partway through

Accepted on 2026-11-04.

## Context

[Decision 19](0019-pull-and-push-from-the-branch-in-the-title-row.md) has a pull that hits a conflict show one alert, with **Undo the Pull** or **Leave It**. After **Leave It**, or for a merge started at the command line or by an agent, the only signs are a row reading **3 uncommitted files** and, once that's selected, a Conflicts heading with red `U` letters. Nothing says a merge is underway. When a rebase stops, `HEAD` is detached, so the title row shows only a hash and **detached**.

That matters most for someone watching several worktrees, because a rebase that stops on a conflict can sit unnoticed, and it can't finish until someone looks.

We drew three options, in dark and light, for merges and rebases with and without conflicts. We also considered an icon on the current branch's badge, since [decision 27](0027-give-the-graph-and-branches-monokais-colors.md) had just taken its checkmark away.

- **On the branch's badge.** An icon that only shows when something's wrong says a lot, but a stopped rebase has no current branch's badge, a commit's row can scroll out of view, and a conflict belongs to the worktree's files rather than to a commit.
- **A filled pill in the title row.** It's impossible to miss, but [decision 23](0023-one-badge-for-a-branch-and-its-upstream.md) keeps a filled shape for where you are, and a second one competes with it for as long as the merge is unresolved.
- **Only the count**, as **⚠ 2 conflicts**. It fits a narrow window, but it doesn't say whether it's a merge or a rebase, and a stopped rebase has nothing else in that row that says so.
- **Words where the counts go.** This is the one we chose.

## Decision

**The title row says it, in place of the counts.** It reads **⚠ Merging · 2 conflicts** or **⚠ Rebasing main · 2 conflicts**, in red, so that the row still reads as a sentence. Pull and push couldn't run then anyway.

**The triangle and the red mean there are conflicts.** With none left, nothing is wrong, but it still isn't finished, so the words stay in gray with no triangle: **Merging · ready to commit** or **Rebasing main · ready to continue**.

**It's a menu.** **Show Conflicts** selects the row for uncommitted changes. **Abort Merge…** or **Abort Rebase…** says what it loses and names the command, then runs `git merge --abort` or `git rebase --abort`.

**The row for uncommitted changes says the same**, as **Merging · 2 conflicts** in red and then **· 3 uncommitted files**. With no conflicts, it reads **Merging · 3 uncommitted files**.

**The sidebar shows conflicts without selecting anything.** A worktree's count turns red with a triangle in front of it. A row that hides worktrees does the same if any of them has conflicts.

**It only reports what git records.** `MERGE_HEAD`, `rebase-merge` and `rebase-apply` say what's underway, and `git status` says which files conflict. This isn't agent status, which stays on hold and comes from hooks ([decision 16](0016-a-rail-of-organizations-in-the-sidebar.md)).

## Consequences

- Each time yaga looks at the selected worktree, it runs one more `git rev-parse` and checks three paths. The sidebar runs nothing new, because the status it already reads lists conflicted files.
- It updates when yaga looks, which is when it becomes active and after something it ran, the same as the counts. A merge started while yaga stays in front shows the next time it looks.
- Conflicts from anything else, such as `git stash pop`, `git cherry-pick` or `git revert`, read just **2 conflicts**, with nothing to abort. `git am` also uses `rebase-apply`, but `git rebase --abort` wouldn't undo it, so it counts the same way.
- yaga can't commit or continue a rebase yet, so **ready to commit** still means finishing from the command line. A conflict editor needs its own decision.
- The menu on the branch's chip still offers Pull and Push during a merge. git refuses them, and an alert says why.
- With Monokai's colors, the red is close to the pink of the graph's first column. The triangle and the words do more to set it apart than the color does.
