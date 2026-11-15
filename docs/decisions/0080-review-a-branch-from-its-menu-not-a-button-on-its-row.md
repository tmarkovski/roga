# 80. Review a branch from its menu, not a button on its row

Accepted on 2026-11-15. This changes how [decision 56](0056-the-panels-show-a-run-of-commits-two-commits-a-branch-or-a-stash.md) let a branch be reviewed from the refs panel.

## Context

Decision 56 gave a local branch's row in the refs panel a button with Lucide's `git-compare` that showed on hover and reviewed the branch against the main branch. Its menu had **Review Against main** as well, and Branch > Review Against main, with Shift-Command-R, reviews the branch the worktree is on. So the button was a third way to do something the row's menu already does, and it showed on almost every branch row, beside the Show Worktree button that only some rows need.

## Decision

**A branch's row has no button for reviewing it.** It's reviewed from its menu, or from the Branch menu for the branch the worktree is on. A branch that another worktree has checked out still shows the Show Worktree button on hover, and other branch rows show nothing on hover.

## Consequences

- Reviewing a branch other than the current one takes a right-click and a choice from its menu, rather than one click on its row.
- The hover button on a branch row now always means the branch is checked out somewhere else.
