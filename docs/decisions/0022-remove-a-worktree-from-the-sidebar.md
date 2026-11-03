# 22. Remove a worktree from the sidebar, saying first what would be lost

Accepted on 2026-11-03, and built straight away rather than waiting for release 2.

## Context

Agents leave worktrees behind, and someone watching several of them wants to tear one down from the place they see it. `git worktree remove` does that, and it refuses when a worktree has changes, so the obvious design is to run it, show its refusal, and offer `--force`. Most Git clients stop there.

We tried what git actually lets through. It exits successfully, with no warning, and deletes all of these:

- ignored files, such as a `.env` or a build folder that took an hour to make
- untracked files, when `status.showUntrackedFiles` is off, because its check is a plain `git status`
- commits that only the worktree's detached `HEAD` leads to, along with the worktree's reflog, which leaves nothing pointing at them
- a rebase that has stopped with nothing to commit

So git's refusal isn't a good enough answer to what someone would lose, and the vision asks destructive operations to say what they'll do before they do it.

## Decision

**A linked worktree's menu has Remove Worktree….** It's in the menu that opens from the row's button and in its context menu. The main worktree's row doesn't have it, and git refuses the main worktree anyway.

**yaga looks through the worktree first, and says what would be lost.** The alert names the folder it deletes, and lists uncommitted changes, untracked files, ignored files and folders, commits only a detached `HEAD` has, a merge or rebase that's partway through, and submodules. It names up to three of each. A worktree with nothing to lose says that.

**Forcing is its own button.** The button says **Remove** when git would agree, and **Force Remove** when git would refuse, which runs `git worktree remove --force`. Having only ignored files or a detached commit to lose doesn't take force, because git doesn't refuse them, but the alert still lists them. Submodules take force, because git refuses a worktree that has them checked out, whatever state they're in.

**yaga looks again before deleting anything.** An agent can keep writing while the question is open, and someone agreed to lose what they were told about. If that changed, nothing is deleted, and the alert comes back with the new list and says it changed. This also means a clean worktree that picked up a file never gets forced by a button that said **Remove**.

**Refusals are alerts, and a lock stays a lock.** When git refuses, an alert shows what git said and nothing changes. `--force` doesn't go past a lock, only `-f -f` does, and yaga doesn't offer that. A lock is someone saying not to touch the worktree, so unlocking it is theirs to do.

**A branch goes only if that loses nothing, and only if someone asks.** Tearing down a finished worktree usually means its branch too, but its commits may not be merged anywhere. So when the main branch has all of a branch's commits, the alert adds a button, **Remove and Delete Branch**, or **Force Remove and Delete Branch**. Otherwise there's no such button, and the alert says the branch stays, with its commits. The main branch is the one the refs panel compares with, and either the local one or its remote one having the commits counts, so that a branch merged on a host doesn't have to wait for a pull. The main branch itself is never offered.

yaga checks for itself and runs `git branch -D`, rather than leaving it to `git branch -d`, which goes by the branch's upstream or by the `HEAD` of wherever it runs. That refused a branch merged into `main` while the main worktree was on another branch, and it would let go of a branch that's pushed but not merged. yaga checks again right before deleting, because deleting a large folder can take minutes and the main branch could move in that time.

**A window that shows the worktree moves to the repository's main worktree,** which is what already happens when an agent removes one. git deletes the folder before anything moves, and a refusal leaves the window where it was. Meanwhile the row says **Removing…**, because deleting a large folder takes a while, and git runs in a task that no view can cancel, since stopping it would leave the folder half deleted.

**A row whose folder is missing can be removed too.** Until now it had no way out in yaga. Its menu has only this command, and the alert says it only makes git forget the worktree.

## Consequences

- Removing a worktree takes one more look at it than git would, about as long as a `git status` and two quick commands, before the alert shows. They all run again when the button is pressed. We haven't measured this on a checkout the size of Linux, where status alone takes about 370 ms.
- A branch merged with a squash or a rebase gets no button, because the main branch has new commits rather than the branch's own, and git can't say they're the same. Those branches stay until someone deletes them from the command line. Hosts often merge that way, so this may be the next thing to look at.
- Deleting a branch by any other route is still for release 2.
- A branch can fail to delete after its worktree has gone, as when another worktree has it checked out. The alert then says the worktree is gone and the branch stays, along with what git said.
- Some of what's in a submodule can't be seen from outside it, such as commits in it that were never pushed. The alert can only say that the submodule goes, with anything uncommitted in it.
- `.DS_Store` shows up as an ignored item in a folder that Finder opened, if the user ignores it globally. It's accurate, and hiding it would be a special case, so it stays until it annoys someone.
- A partial clone that can't run `git status` without downloading can't be looked through, so the alert says what git said rather than asking. It's the same limit the sidebar's counts have.
- If git can't finish deleting the folder, as with files it has no permission to delete, it has already forgotten the worktree. The alert shows what git said, and the row goes, because the worktree really is gone. What's left in the folder stays there for someone to delete.
- This came forward from release 2, as pull and push did. The command is only in the sidebar's menus, like the other commands on these rows, rather than in the menu bar.
- `ChangesLoader.status` gained an option to list untracked files whatever the user's setting says. Only this uses it, because the setting exists for repositories where that's slow, and someone asking to delete a worktree is worth waiting for.
