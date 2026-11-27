# 116. Offer to delete a locked worktree anyway, and show the lock in the sidebar

Accepted on 2026-11-27. Partly supersedes [decision 32](0032-ask-before-forcing-a-worktree-with-submodules.md), which said that a lock still stops a deletion, and the main window's notes, which said Roga won't override a lock.

## Context

`git worktree lock` keeps `git worktree remove` from removing a worktree, and agents lock the worktrees they work in. Claude Code locks each session's worktree with a reason such as `claude session fix-login (pid 56765 start Thu Nov 26 20:57:57 2026)`. Roga treated a locked worktree as one git would refuse whatever anyone answered, so Delete… ran `git worktree remove` straight away and showed git's refusal in a dialog that could only say **OK**. git's own message says how to get past it, with `remove -f -f`, but the only way to do that was the command line, or finding the agent's session and closing it.

A lock is often stale. The session that took it can be archived, or the agent can have stopped without unlocking, and then the lock is only in the way. Someone deleting the worktree from the sidebar has usually already decided that.

Nothing in the sidebar said a worktree was locked, either. The tabs mark a locked worktree with a lock when nothing more pressing is going on ([decision 95](0095-a-repositorys-worktrees-as-tabs.md)), but the sidebar, where Delete… is, showed nothing.

We looked at these:

- **A Delete Anyway button on git's refusal.** It's the smallest change, but the user answers one dialog, gets a second one, and only then learns what forcing would take with it. Decision 32 turned this down for submodules for the same reason, and because it means recognizing git's message, which changes with the language and between versions.
- **`git worktree unlock`, then `git worktree remove`.** This is two commands, and if the second is refused, as with uncommitted files, the worktree is left unlocked for no reason.
- **Asking first, the way a worktree with submodules does.** `git worktree list` already says whether a worktree is locked, and why, so the dialog can say so before anything runs. This is the one we chose.

## Decision

**A locked worktree always asks first,** even when nothing would be lost. The dialog's first words say it's locked, which often means an agent is still working in it, and that git only removes a locked worktree when it's forced twice. The reason the lock gives, if it gives one, is the gray note under the cards, as in "The reason given for the lock: claude session fix-login (pid 56765 …)". Everything else about the dialog is as it was: the switches, what can't be brought back, and the commits.

**It runs `git worktree remove --force --force`.** Both `--force`s are pink in the block. The second one is what gets past a lock, and the two together also get past uncommitted files and submodules, which the dialog already lists. A worktree with submodules that's also locked says that forcing it takes its submodules, without explaining forcing twice.

**The button reads Delete Anyway**, in red, and Return doesn't press it. A worktree with submodules uses the same label, which now follows [decision 102](0102-buttons-in-title-case.md).

**A lock that comes after the dialog opened still stops everything.** What runs was worked out without a lock, so it has no second `--force`, and git refuses it. The dialog that says what git said is still there for that.

**A locked worktree's sidebar row has a gray lock** just before its count, in the label's place ([decision 58](0058-the-mark-under-the-menus-button-and-the-count-before-it.md)). Its tooltip says **Locked**, and the lock's reason after a colon when it has one. Words about the row, such as **Deleting…** and **Folder missing**, take the label's place as before, and the lock goes with the count. VoiceOver reads "Locked" with the row's value.

## Consequences

- A stale lock no longer needs the command line or the session that took it.
- Deleting the worktree an agent is still running in is one click and a confirmation away. The dialog says that's what a lock often means, and the lock's reason usually names the session, but nothing checks whether that session is still running.
- Every worktree that an agent's session has locked shows a lock in the sidebar for as long as the session keeps it, which in some apps is as long as the session exists.
- `Worktree` keeps the lock's reason from `git worktree list --porcelain`, which the dialog and the sidebar's tooltip read. The tabs' tooltip and the repository's menu still say only **Locked**.
