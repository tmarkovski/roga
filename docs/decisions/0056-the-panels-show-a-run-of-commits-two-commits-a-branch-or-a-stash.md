# 56. The panels show a run of commits, two commits, a branch or a stash

Accepted on 2026-11-07.

## Context

Release 1 promises three things that had nowhere to show: everything a branch changed since it left its base, the way a pull request shows it, what a stash holds, and the difference between any two commits. [docs/main-window.md](../main-window.md) listed where they go as an open question, and named a review pane over history as one answer.

We sketched three answers on the Review page of the design canvas, each drawn with the same worktree: an agent's three commits on `agent/fix-login`, one new commit on `main` since the branch left it, and one stash.

- **A. The panels show what you pick.** Nothing new opens. The commit and diff panels show a run of commits, two commits, a branch or a stash, the way they already show a commit or uncommitted changes.
- **B. A review pane over history,** with every file in one scrolling diff and a check for marking each one viewed. It's the closest to a pull request, but it's a mode you go into and come back out of, history is out of sight while you read, and it needs a scrolling diff that [decision 9](0009-diff-view-uses-textkit-1.md)'s text view can't do yet.
- **C. Each comparison as a tab over the panels,** so that a review stays open while you click around history. Tabs need closing, nothing says when one is out of date after an agent commits again, and [decision 10](0010-our-own-tabs-in-one-window.md) turned tabs down once already.

The user chose A.

## Decision

**History can select more than one row.** Shift-click selects a run of rows and Command-click adds or removes one, as in any list on the Mac. Selected rows next to each other make one gray block, with rounded corners only at its ends. The row for uncommitted changes is never one of several: it's left out of a run, and Command-clicking it selects it alone.

**What several commits show depends on how they're related.**

- **A run on one line,** where each commit's first parent is the next one down, is one diff from the oldest commit's parent to the newest commit. The panel's title says how many there are, as in **3 Commits**, and under it which commits the diff goes from and to. A run that goes down to a root commit compares with nothing, so its files are added. History lists a commit before its parents in either order, so the rows decide which is the newest.
- **Two other commits are compared,** from the lower row to the upper one, with `git diff-tree` between them. The title is **Compare**, then the two short hashes with an arrow, and the panel lists each one with its subject. A button with Lucide's `arrow-left-right` swaps them.
- **Three or more that aren't a run** don't make one diff, and the panel says so and asks for a run or two commits instead.

**A branch is reviewed against the main branch.** That's the branch `origin/HEAD` names, or a local `main` or `master`, as for the counts beside a branch. A local branch's row in the refs panel shows a button with Lucide's `git-compare` on hover, and its menu has **Review Against main**. Branch > Review Against main, with Shift-Command-R, reviews the branch the worktree is on. The main branch itself, and its upstream, have nothing to review against.

- The base is the latest commit that the branch shares with the main branch or its upstream, which is what `git merge-base` gives for the branch and the two of them. A local `main` that's behind `origin/main` doesn't pull `origin/main`'s commits into the review.
- History selects the commits the branch has that neither of them has, from `git rev-list`, up to 10,000, and marks the base with a badge that says **merge base**. The panels show one diff from the base to the branch's tip. The commit panel's title is the branch's name followed by **since main** in gray, and under it how many commits there are and where it left main, with the latest commit's subject.
- A review follows its branch. When history loads again because a ref moved, as when an agent commits, the review is read again, and it changes if the branch's tip or base did. A branch that's gone leaves nothing selected.
- A branch with no commit in common with the main branch has no base, so its review compares with nothing and says so.

**Clicking a stash shows what it holds.** Its row in the refs panel selects it, and history selects no row and marks the commit the stash was made on with the stash's name, as in **stash@{0}**. The commit panel's title is **Stash** with its name, and the panel has the stash's message, the commit it was made on, which selects that commit in history, and when it was made. Its files are under the headings uncommitted changes would have, without their buttons, from the commits git keeps for a stash:

- **Staged** is what changed from the commit the stash was made on to the stash's index commit, its second parent.
- **Unstaged** is what changed from the index commit to the stash's own commit.
- **Untracked** is everything in the stash's third parent, when the stash kept untracked files.

A heading with no files doesn't show. The diff panel's header says which heading a file is under, as it does for uncommitted changes.

**Selecting anything else ends it.** Clicking a commit, the row for uncommitted changes or another ref shows that instead, and the mark goes. Clicking the one commit a review selected shows that commit, though the row was already selected.

**The commit and diff panels stay as they are.** The list of files, the filter, the tree, the arrow keys and the diff work the same for every kind, and Maximize from [decision 52](0052-maximize-or-minimize-the-panels-under-history.md) gives a large review the room. Edit > Copy Commit Hash copies a stash's hash too, and does nothing for several commits.

## Consequences

- History stays the one list of commits, so there's nothing to keep in step with it, and comparing anything is the same `git diff-tree` between two commits, which the session already runs for one.
- A large change is read one file at a time in a 320-point list, with nowhere to mark files as viewed. B's scrolling diff could still come later, inside the diff panel, and the review pane stays among the options [docs/main-window.md](../main-window.md) keeps open.
- A review goes away when someone clicks another commit, and only one thing shows at a time, so a branch and a stash can't be open together, as they could in C.
- A remote's branch has no Review yet, and the refs panel's arrow keys still skip stashes.
- File history is still to be placed, and the panels are where it would go first.
