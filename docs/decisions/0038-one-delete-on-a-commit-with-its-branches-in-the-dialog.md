# 38. One Delete… on a commit, with its branches in the dialog

Accepted on 2026-11-05. Replaces what [decision 33](0033-one-row-in-a-menu-and-the-choice-in-the-dialog.md) says about a branch and its upstream sharing a row in history, and goes further than it did against [decision 29](0029-dialogs-that-say-what-happens-and-show-the-command.md)'s rule about adding no questions. The rest of both decisions still holds. [Decision 44](0044-revert-a-commit-from-its-menu-in-history.md) puts **Revert…** above **Delete…**, so a commit with no branch that could go has a menu too.

## Context

Decision 33 gave a branch and its upstream one row in a commit's menu, and left everything else as it was. Every other branch on the commit kept a heading and a row of its own, so a busy commit opened a menu of headings with the same word under each. Deleting two branches that didn't share a badge still meant opening it twice, and the row's words changed between **Delete Branch**, **Delete…** and **Delete from Remote…** for reasons that had nothing to do with what someone wanted. The menu had also grown a disabled row for the current branch and separate rows for what shares its badge.

The user asked for one **Delete…** on a right-click, with the local and remote branches chosen inside it, rather than separate sections.

## Decision

**A commit's menu has one item, Delete….** Its dialog lists every branch on the commit, each with a switch, whether it has a badge of its own or shares one: local ones first, then remote ones from A to Z. Decision 33 put a choice of how far to go in a dialog. This puts the choice of which branches there too.

**It always opens a dialog.** The ellipsis promises one, and the menu can't know what would be lost without running git. Letting a lone local branch that loses nothing go straight away, as it used to, would save a key. But the same row would then sometimes ask and sometimes not, for reasons that nothing on screen shows, and a deletion can't be undone from here.

**What starts on follows decision 33.** It goes as far as it can without losing a commit, and it never reaches a remote. So every local branch starts on and no remote branch does, including one whose remote isn't configured any more, because anything under `refs/remotes` being off is easier to predict. Return then clears away local branches and leaves everything on the remote alone.

**Local branches that would take commits with them all start off.** This happens when they're all that's on the commit and nothing else leads to it. Going as far as possible would mean deleting all but one, but nothing says which name to keep, and the two names are all that differ. So **Delete** is disabled until someone picks. The same goes for a commit with only remote branches, whose switches are off anyway. That's a click more than **Delete from Remote…** took, and it means no key press can reach a remote without someone choosing to.

**One branch has no switch.** With only one that can go there's nothing to choose, and **Cancel** already says no. A switch could only make a dialog with nothing to do. It gets the dialog the refs panel uses, whose title names the branch, and its button follows decision 29: ink when nothing's lost and no remote is involved, which Return presses, and otherwise red.

**A branch that's checked out stays, and a line says so.** git won't delete it, so it has no switch: a switch that can't flip costs a row and says less than a sentence does. A note under the cards reads "`main` stays, because git won't delete a branch that's checked out", and names every such branch. That covers the current branch, and branches in other worktrees, which the dialog can tell because the session reads the worktrees and the menu doesn't.

**A commit with nothing to delete has no menu.** That's a commit with only the current branch, which now behaves like one with no branches. A menu with one gray row wouldn't say why it was gray. The item is only disabled while git is running something else. When a commit's only branch turns out to be checked out in another worktree, which the menu can't tell, git is asked anyway and a dialog shows its refusal, because that names the worktree.

**One count covers every combination.** The branches on a commit all lead to the same commits, so any one that stays keeps them all. What's lost has only two answers, which are nothing, and what goes when every branch does. `CommitBranchesDeletion` works that out once with `git rev-list`, however many branches there are, and flipping a switch only reads it. `BranchAndUpstreamDeletion`, which it replaces, counted three combinations for two branches, and doing that here would mean a count for every subset. When there's anything to lose, the commits are listed from the start, as decision 33 asks, under words that say whether they stay or can't be brought back.

**A branch that has moved is left out.** The count only holds while the branches are all on that commit, and an agent may have committed to one since history last looked. So the commit comes along with the names, and a branch that's no longer on it isn't offered, rather than being offered with a count that doesn't cover what it moved to. If none are left, a dialog says so and history looks again.

**Nothing moves when a switch flips, whatever the names are.** Each switch that's off leaves room in the block for its command, as tall as that command would be, because a long name takes two lines where an empty line would only leave one. The heading over the commits stays on one line and shortens a long name in the middle, since the name is in full on its switch. The card of switches scrolls past five and a half rows, and the block already scrolls past 220 points, so a commit with 30 branches gets a dialog the same size as one with 20.

**The keys are numbers.** The first nine switches flip with 1 to 9, and each tooltip says which. B and R can't stretch to any number of branches. The worktree's dialog has at most one of each, so it keeps them.

**Deleting stops at the first refusal.** Everything local goes before anything on a remote, so that git refusing a branch stops everything before anyone else sees a change, as decision 33 has it for a branch and its upstream. Past the first, the dialog says what's gone and what isn't.

**The refs panel doesn't change.** Each of its rows is one branch, so it has nothing to choose, and it still deletes a local branch straight away when nothing's lost.

## Consequences

- A lone local branch that loses nothing takes a right-click, **Delete…** and Return from history, where it took a right-click and a click. Deleting several in a row is slower than it was, unless they're on one commit. The refs panel is the quick way for that.
- A remote branch on a commit with other branches takes one click more, because its switch has to be flipped as well as **Delete** pressed. Anything that took several trips through the menu takes one.
- Return can delete more than one local branch. With `main` and `feature` on one commit while something else is checked out, both start on, even if only `feature` was meant. Nothing's lost, because something else still leads to the commits, and the switches and commands are in front of whoever presses it, but `main` does have to be made again.
- Right-clicking a commit with only the current branch does nothing, which could look broken, and nothing says why.
- The title can't name a branch, so it reads "Delete which branches?", and the switches say the rest.
- A switch's words are the same for every local branch, which reads as repetition on a commit with many.
- A dialog for eight branches is about 550 points tall, and more with commits to list. It hasn't been looked at in a window shorter than that.
- Between the dialog opening and **Delete** being pressed, a branch can still move, and `git branch -D` wouldn't notice. That's as it was for a branch and its upstream.
- `TerminalLine.room` is only used here. The worktree's dialog still leaves empty lines, so a long remote command there can still need more room than it has.
