# 75. List submodules in the refs panel, and go into one in the window

Accepted on 2026-11-10. The first two of its three steps were built the same day, and the third isn't built. Building the first added two cases that this doesn't name, which [the main window](../main-window.md#the-commit-and-diff-panels) describes: a checkout that hasn't fetched the commit that's recorded, which is treated as one that's behind, and a checkout with commits of its own that's missing some too, which has Update and Stage in a menu and neither as a button. Building the second settled three things this leaves unsaid, which [the refs panel](../main-window.md#the-refs-panel) describes: a submodule is a path that `.gitmodules` names and the index records a commit for, a row whose checkout is in two states at once says both, and a submodule that isn't checked out has no button yet. A row's **Open** and its double-click wait for the third step.

## Context

Roga shows a submodule as a row like any file, with git's two `Subproject commit` lines for a diff. Git reports three different things as that one modified row: a checkout that's behind the commit the branch records, a checkout with commits the branch doesn't record yet, and files changed inside the submodule. Nothing says which it is. Staging the first one records the older commit, which is how a branch loses an update someone else made. The refs panel and the sidebar don't list submodules, and going into one means adding its folder as a repository by hand.

Until now Roga only dealt with submodules where one of its own commands ran into them: fetching ([decision 20](0020-fetch-when-yaga-becomes-active.md)), deleting a worktree ([decision 32](0032-ask-before-forcing-a-worktree-with-submodules.md)), discarding ([decision 39](0039-discard-with-undo-and-ask-only-for-many.md)) and gathering facts after git refuses ([decision 63](0063-ask-an-agent-to-fix-what-git-refused.md)). The [roadmap](../../ROADMAP.md) left the rest for a decision of its own. Agents make it matter more, because they check out submodules to build, and they update them in commits that someone then has to review.

A submodule is three things at once: a commit that the parent's tree and index record for a path, a few settings in `.gitmodules`, and a repository checked out inside one worktree. Which submodules there are, which commit each is pinned to and whether it's checked out all belong to the worktree rather than the repository, since each linked worktree keeps its own copies.

We sketched three answers on the Submodules page of the design canvas, each drawn with the same worktree: `agent/fix-login` in `agents-demo`, where `vendor/parser` is three commits behind what the branch records.

- **A. A section in the refs panel, and the window goes into one.** The refs panel lists the worktree's submodules after Stashes. Clicking one shows where it stands in the panels under history, and Open shows the submodule's own repository in the window, with a path in the title row and the sidebar as it was.
- **B. Rows under each worktree in the sidebar.** That's true to what a submodule is, a checkout inside one worktree, and it needs no new section. But the sidebar is for looking across repositories, and three submodules in each of four worktrees is twelve more rows that are nearly always quiet, on a third level. A click there can only go in, so nothing shows how a submodule stands from outside.
- **C. A repository of its own in the sidebar.** Opening a submodule adds it to the list like any repository. Nothing then ties it to its parent, [decision 14](0014-the-sidebar-keeps-every-added-repository.md) keeps it there until someone removes it, and the same submodule in another worktree is a second row with the same name.

The user chose A.

## Decision

**Roga keeps a submodule's boundary in view.** It says which commit the worktree records, which one is checked out and what lies between them, and it lets someone go into the checkout as the repository it is. It doesn't mix a submodule's files or commits into the parent's lists, and it runs nothing inside a submodule by itself.

It comes in three steps, in this order, and each is worth having without the next.

**First, a change to a submodule's pointer reads as what it is,** wherever its row already shows: in a commit, in several commits or a branch's review ([decision 56](0056-the-panels-show-a-run-of-commits-two-commits-a-branch-or-a-stash.md)), and under uncommitted changes.

- The row keeps its status letter and gets a box icon. In place of line counts it says how the pointer moves: `3 commits` in a commit, and for uncommitted changes `3 behind`, `2 new commits` or `2 files inside`.
- The diff panel's header says **Submodule**, and the panel lists the submodule's commits between the two hashes, with each one's short hash, subject, author and date, under a band that says which way they go, as in `52e8a1b → 9d41c07 · 3 commits forward`. A pointer that goes back says so in red. The commits are read from the copy checked out in the worktree, so a submodule that isn't checked out there shows only the two hashes.
- **Behind** is a checkout that's missing commits the worktree records, which is what a pull or a rebase leaves. The panel lists the commits it's missing, and the button is **Update**, which runs `git submodule update --init -- <path>`. Staging the row stays in its menu, for someone who means to go back.
- **New commits** is a checkout with commits the worktree doesn't record. The button is **Stage**, which records the checked-out commit, and the panel says when those commits aren't on any of the submodule's remotes yet.
- **Files inside** is a checkout at the recorded commit with uncommitted files of its own. The parent can't stage those, so the row has no Stage, and the panel lists the files without their diffs. The button is **Open**, once the third step gives it somewhere to go.
- **Stage All leaves out a submodule that staging would take commits away from,** which is one that's behind, or one that has commits of its own and is missing some too. The title row says what it left and why. Stage All and Commit does the same. `git add -A` would stage it, and that's the accident this step is for.

**Second, the refs panel lists the worktree's submodules,** in a section named **Submodules** after Stashes. Like Tags and Stashes, it isn't there until there's one to show.

- A row has a box icon and the submodule's path. Its second line has the short hash that's checked out and where that stands, as in `52e8a1b · 3 behind what's recorded`, `e7a90b2 · 2 new commits`, `9d41c07 · 2 uncommitted files` or `9d41c07 · as recorded`, and the same shows beside the name as `↓3`, `↑2` or a count in orange. One that was never checked out in this worktree is dimmed and says `not checked out`.
- Clicking a row shows the submodule in the panels under history, as clicking a stash does. History selects no row. The commit panel's title is **Submodule** with its path, and it has the commit that's recorded, the commit that's checked out, and where it's from, which is its URL without a user name or password. The diff panel shows what the first step shows for its row, with the same buttons.
- **Open** shows on the row while the pointer is over it, and double-clicking the row does the same.
- The section is read for the worktree in the window, and read again when the window shows another one. It's the first section that belongs to a worktree rather than to the repository.

**Third, Open takes the window into the submodule.** The window shows the submodule's own repository, with its history, its panels and its refs, in the checkout that's inside this worktree.

- The title row becomes a path: the parent's name, a chevron, then the submodule's path with the box icon, then what `HEAD` is on. A submodule's `HEAD` is usually detached, and reads as it does anywhere else in Roga, followed by how far the checkout is from what the parent records, as in `detached · 3 behind agents-demo`.
- Clicking the parent's name goes back to the worktree. Its menu of worktrees ([decision 40](0040-the-repositorys-name-opens-a-menu-of-its-worktrees.md)) opens from there, as before.
- History marks the commit the parent records with a dashed badge that says **recorded by agents-demo**, as a review marks the merge base.
- The sidebar doesn't change. The worktree's row stays selected, and its count already includes the submodule, because git counts it. Roga never adds a submodule to the sidebar by itself. File > Open on its folder still adds it as a repository of its own, for someone who works in it all day.
- A commit made there on a detached `HEAD` is covered by what Roga already does before commits would be lost ([decision 37](0037-double-click-a-commit-to-go-to-it.md)), and the heading over the message says **Commit on a detached HEAD**.

**Nothing recurses by itself.** Roga's own fetches stay out of submodules (decision 20), and a pull updates them only when `submodule.recurse` says so, which is git's doing rather than Roga's.

## Consequences

- Reading a submodule's commits takes a checkout of it, and counting how far it is from what's recorded takes a `git rev-list` inside it. `git status` already looks inside every checked-out submodule. So the counts on the rows load after the list shows, to keep a worktree's status within its 300 ms.
- [Decision 49](0049-look-again-at-what-changes-on-disk.md)'s watcher leaves out `modules/`, so a commit made inside a submodule doesn't change the parent's count until something else does. The third step has to watch the git directories of the submodules checked out in the worktree on screen.
- Decision 32's dialog still says that nothing has looked inside a worktree's submodules. Once the second step reads them, it could say what forcing would lose.
- These are still open, and none of them holds up the first step:
  - whether a push passes `--recurse-submodules=check`, so that git refuses to push a pointer to a commit that's on none of the submodule's remotes
  - whether New Branch offers to check out submodules in a new worktree, which starts with their folders empty
  - how the title row's path reads for a submodule inside a submodule, and which key goes back, where Finder's Command-Up Arrow for the enclosing folder is the likely one
  - whether the section's heading gets Update All
  - adding and removing submodules and changing their URLs, which would follow [decision 67](0067-add-and-remove-remotes-in-the-refs-panel.md)'s dialogs for remotes
- The roadmap listed submodules under what isn't planned. This decision says what to build and in which order, and scheduling the steps is separate, so the roadmap now lists the two steps that aren't built there. Git LFS still needs a decision of its own.
