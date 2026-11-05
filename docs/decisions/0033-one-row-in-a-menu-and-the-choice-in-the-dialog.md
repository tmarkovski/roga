# 33. One row in a menu, and the choice in the dialog

Accepted on 2026-11-04. What this says about a branch and its upstream in a commit's menu is replaced by [decision 38](0038-one-delete-on-a-commit-with-its-branches-in-the-dialog.md), which has one **Delete…** for everything on the commit. The rest of this decision still holds.

## Context

A linked worktree's menu had **Delete** as a submenu with three rows, for the worktree alone, with its branch, and with its remote branch too. That took three clicks: the right-click, **Delete**, and how far to go. Anything that would lose something or reach a remote then took a fourth, in a dialog that came after the choice had been made. A row in a submenu has no room to say what it would cost, so people chose first and found out afterwards, and Return can't choose a row in these menus (https://github.com/tmarkovski/yaga/issues/12).

A commit's menu in history had a smaller version of the same thing. A branch and its upstream on one commit, which [decision 23](0023-one-badge-for-a-branch-and-its-upstream.md) draws as one badge, were two rows under two headings, and deleting both meant opening the menu twice.

We drew the options on the design canvas, on its Menus page. All of them have one row in the menu, and they differ in how the dialog holds the choice:

- **Switches for what else goes.** Every option deletes the worktree, so the switches only say what else does, and each adds its own line to the command. This is the one we chose.
- **Rows, then a button.** Each row is a whole result, which makes it the clearest to read, and it's how the first drawing of rebase or merge asked. It's the tallest, it has a row for keeping the branch where a switch can just stay off, and it can't offer every combination.
- **Rows that run when clicked.** This takes the fewest clicks, three for every option, because there's no second button. But a click one row too low could delete a branch's only copy of its commits or delete from a remote, and nothing would catch it. With a choice and a button, that same slip only changes the choice, and the button turns red.

## Decision

**Items in one menu that do the same thing to the same target, and differ only in how far they go, share one row.** The row ends in an ellipsis, and the choice goes in that action's dialog. That dialog is also the confirmation, so nothing asks again afterwards.

**Items whose action has no dialog stay as they are.** Adding a dialog just to hold a choice would cost a click. So **Push** and its force push under Option don't change, and neither do **Show in Finder** and **Open in Terminal**. **Pull…** already worked this way ([decision 29](0029-dialogs-that-say-what-happens-and-show-the-command.md)). Nothing used `RefMenu`'s submenus after this, so they're gone.

**A worktree with a branch always opens the dialog.** This goes against what decision 29 says about adding no questions, and it's the part of that decision this one replaces. A clean worktree used to delete without a dialog, and it opens one now because that's where the choice lives. It still takes three clicks, and two keys with Command-Delete and Return. A worktree with no branch to take along has nothing to choose, so it keeps a plain **Delete Worktree** that runs straight away when nothing would be lost.

**What's chosen to start with goes as far as it can without losing a commit, and it never reaches a remote.** The branch's switch starts on, unless the branch has commits that nothing else has. The remote branch's switch always starts off. So clearing away an agent's merged work is a right-click, **Delete…** and Return.

**The two switches are independent.** That makes four combinations where the submenu had three, because a remote branch can now go while the local branch stays.

**The button follows decision 29.** It's red, and Return doesn't press it, when something can't be brought back or a remote is involved. Otherwise it's ink, and Return presses it. The same switch can move it from one to the other.

**Nothing moves when a switch flips.** A sheet can't change size once it has opened. So the terminal block keeps an empty line for each command a switch could add, and the commits that the switches could lose are listed from the start, under words that change from staying to being lost. What's lost whatever the switches say, such as uncommitted files, comes before them.

**yaga works out every combination before the dialog opens.** It looks in the worktree once, and counts lost commits for each combination. `WorktreeDeletion.Choice` holds the results, and flipping a switch only reads them. The menu no longer needs to know whether a branch has a remote branch, so the sidebar stopped reading that every time it looks at a repository's worktrees.

**A branch and its upstream on one commit share a row in history.** The row is **Delete…**, and its dialog has a switch for each, starting with the branch on and the upstream off. With both off, **Delete** is disabled. The current branch can't be deleted, so it keeps its disabled **Delete Branch**, and its upstream keeps its own **Delete from Remote…**. A branch that another worktree has checked out can't go either, which history can't tell ahead of time, so that row goes straight to the dialog for the upstream.

**Keys.** **Delete Worktree…** in the File menu, Command-Delete, does what the row's menu does for the selected worktree. It's only enabled while the keyboard is in the sidebar, because a menu's shortcut comes before a text field's, and Command-Delete has to go on deleting a line in a commit message. `onKeyPress` on the sidebar didn't receive it when we tried. In a dialog, B flips the switch for the branch and R the one for the remote branch, and each switch's tooltip says so. A dialog has nothing to type in, so they need no modifier.

## Consequences

- A few things take a click more. Keeping the branch of a clean, merged worktree takes four clicks where it took three, because the dialog starts with it going. Deleting only the local branch from a commit's menu takes three where it took two. Deleting both goes from five to four, and anything that asked before takes a click less when what's chosen to start with is what you want.
- The refs panel's rows stay as they were, because each has one delete. So the same branch gets a different dialog from the refs panel than from history.
- Preparing a deletion counts lost commits for up to four combinations, with two `git rev-list`s each, where it used to count one. They run at the same time, and they haven't been measured on a large repository.
- The dialog's title can't say how far the deletion goes any more, because it can't change without risking a second line in a sheet that can't grow. It names the worktree, and the switches and the block say the rest.
- A dialog with the commits listed from the start is taller than one that only lists them once they'd be lost.
- Letters as shortcuts only work while nothing has focus for typing. A dialog with a text field couldn't use them.
