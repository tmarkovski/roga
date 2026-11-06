# 49. Look again at what changes on disk

Accepted on 2026-11-06.

## Context

Release 1 is for someone who works in the terminal and keeps Roga open beside it, to watch what they and their agents change. Until now Roga only looked again at a worktree when it became the active app, when a window showed the worktree again, or on View > Reload. While someone watched from the terminal, Roga wasn't active, so the sidebar's counts, the row for uncommitted changes and history went stale exactly when they were being watched. The agents' marks moved, because hooks drive them (decision 41), but what they pointed at didn't. And each time Roga did become active, it ran `git status` in every worktree of every repository, about 100 git processes on the user's machine ([docs/performance](../performance/2026-11-03-actions-waiting-on-background-work.md)).

The roadmap's release 1 lists live refresh with FSEvents, and ARCHITECTURE.md planned one stream for each repository. What it left open was how to keep that cheap while an agent builds, which can write thousands of files a second, nearly all of which git ignores.

## Decision

**Each repository's session watches its git directory and its worktrees' folders with one FSEvents stream,** reports what each batch of changes affects, and Roga reads only that. A batch arrives about 100 ms after the first change in it. Refs and `HEAD` moving load history again and update the branches. A worktree's index, its files, or what it's stuck partway through, recount that worktree only. A worktree coming or going lists the worktrees again.

**Roga asks git which changed files it ignores, and skips those.** `git check-ignore` answers for the files and the folders they're in, and Roga remembers ignored folders, so a build's output costs a handful of `check-ignore`s rather than a `git status` for every batch. git never looks inside an ignored folder, and it doesn't call a folder ignored while the index has a file in it, so remembering folders can't hide a change git would show.

**While changes keep coming, each look waits until the one before it is half a second behind, or twice as long as it took, whichever is longer.** So git runs at most half the time, and twice a second in a small repository. The first change after a quiet spell is looked at straight away. The sidebar and a window looking at the same worktree because of the same change share one `git status`.

**Roga no longer looks again when it becomes the active app,** except at repositories it couldn't open or can't watch, as on a volume that doesn't record changes. It still fetches then (decision 20), and View > Reload still looks at everything.

## Consequences

- The sidebar, the row for uncommitted changes, history, the branches in the title row and the refs panel follow the terminal and the agents as they write, whether or not Roga is in front.
- In a test copy of a Debug build on an M1 Max, Roga ran no git at all while nothing changed. Saving a tracked file every 50 ms for 10 seconds ran 21 `git status` and one `check-ignore`. Writing 120,000 files into an ignored folder in 10 seconds ran 13 git commands, most of them two full looks after FSEvents fell behind and reported only that something changed.
- History loads again whenever a ref moves, as it did after a commit made in Roga, rather than inserting new commits at the top as ARCHITECTURE.md once planned. On Linux the first screen is back in about 50 ms and the rest orders in the background in about a second.
- A commit inside a submodule changes only files in the git directory's `modules/`, which Roga doesn't watch, so the parent's count follows once something else changes there, or on View > Reload.
- Roga notices a change to `info/exclude`, a `.gitignore` or the repository's config, and asks git again. It doesn't watch a global excludes file outside the repository, so a change there takes effect for a worktree once its index or a `.gitignore` changes.
- FSEvents only reports changes made on this Mac, so on a network volume a change made from another computer shows on View > Reload.
- Becoming active no longer starts about 100 git processes.
