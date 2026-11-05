# 37. Double-click a commit to go to it

Accepted on 2026-11-04.

## Context

Double-clicking a branch's badge checked the branch out, and double-clicking anywhere else in a row did nothing. Going back to an older commit took the command line. People usually want that either to look at an older state or to throw away a few commits, and most of the time every commit involved is already pushed, so nothing can go wrong and a question would only get in the way.

What going to a commit could mean in git:

- **Always detach `HEAD`.** `git switch --detach` can't lose anything on a branch, so it never needs a question. But it doesn't do what someone who wants to go back on their branch is after, and it leaves them on no branch.
- **Reset with `--hard`.** It's what people often type, and it destroys uncommitted changes without a word.
- **Reset with `--keep` when the commit is on the branch's line, and detach when it isn't.** This is the one we chose.

## Decision

**A row with another branch on it goes to that branch**, as the branch's badge does, so nothing moves and nothing is left behind. Double-clicking a row can't reset onto a commit that has a branch on it, because the branch is the likelier meaning.

**A commit on the branch's line moves the branch.** A commit is on the line when the branch or its upstream leads to it. That covers going back, going forward again along the upstream, and going across to the upstream of a branch that has diverged, which is the usual way to throw away local work. A remote's copy of the current branch has nothing to check out, so its badge does the same.

**A commit anywhere else detaches `HEAD`.** Moving a branch onto another line is never what someone means by double-clicking a commit there. The branch stays where it is, so this loses nothing.

**`--keep`, not `--hard`.** It carries uncommitted changes along, and refuses when they're in the way, which is what a checkout already does. A row that does nothing else shouldn't be able to destroy someone's work.

**It asks only when commits would be lost.** Lost means what it means when deleting a branch: no other branch, remote branch, tag or other worktree's `HEAD` leads to the commit. This isn't quite the same as not being pushed. A commit that's only on another local branch isn't pushed, but saying it would be lost would be false.

**The dialog offers a way to keep them.** It lists the commits, and offers **Cancel**, **Reset anyway** and **Push, then reset**. Following [decision 29](0029-dialogs-that-say-what-happens-and-show-the-command.md), **Reset anyway** is red and takes a click or Command-Return, and **Push, then reset** is ink and Return presses it. When there's no remote, or git would reject the push because the upstream has moved on, there's no push to offer. A note says so when it's because the upstream has moved on. Copy gives the push and then the reset, so what gets pasted is the version that keeps the commits, and a comment in the block says that **Reset anyway** skips the push.

**Leaving a detached `HEAD` asks too.** That's the one way that checking out a branch can lose commits, and detaching on a double-click makes it easier to end up there, so a badge asks as well, with **Switch anyway**.

**What was counted is what runs.** A dialog can stay open for a while, and an agent can commit meanwhile. So `HEAD` is checked just before running, and if it has moved, nothing happens and a dialog says so.

**A worktree stuck partway through a merge or a rebase does nothing.** git would refuse anyway, but only after a question about commits that aren't really at risk.

## Consequences

- A stray double-click on a row can move the branch with no question when nothing would be lost. It's easy to see, because the branch's badge moves to the row and the title row says how far behind it is. When the commits are on the upstream, a pull or a double-click on the upstream's row brings it back.
- A reset leaves what was staged unstaged, because `--keep` resets the index. The files keep their changes, but the staging has to be done again. `git switch` doesn't do this, so it's a difference between going to a commit on the line and going to one elsewhere.
- Remote branches are as of the last fetch. A commit that someone has since removed from the remote still counts as being there until a fetch says otherwise.
- `git reflog` can still find lost commits, and the dialog says so, but Roga has no way to bring them back yet.
- Rows can change order when `HEAD` moves, so the row someone double-clicked may move away from the pointer. It stays selected, though.
- The dialog for a badge from a detached `HEAD` shows `git switch <branch>`, as someone would type it. For a remote branch with no local copy, Roga runs the longer command that `git switch` would imply, and a failure shows that one.
- The command in the block has the whole hash, so it usually takes two lines.
