# 118. Branches on one line, merged branches, and what the pointer lights up

Accepted on 2026-11-27. This changes how the refs panel draws its branches and remote branches. It takes back the second line a local branch had and the date at the end of a remote branch's row, gives the panel's counts the tabs' gray in place of [decision 27](0027-give-the-graph-and-branches-monokais-colors.md)'s green and pink, makes the icons and indents of [decision 50](0050-branches-in-folders-at-each-slash-of-their-names.md) smaller, and lets the delete dialog from [decision 38](0038-one-delete-on-a-commit-with-its-branches-in-the-dialog.md) ask about branches on different commits. The options were drawn on the Branches page of the design canvas, with this repository's own branches, and [`docs/design/branch-list/`](../design/branch-list/README.md) has the script that draws them.

## Context

A local branch took two lines and every other row in the panel one. Most of the second line repeated the row: `up to date with origin/tm/commit-box-composer` restated the branch's own name, and `1 ahead, 120 behind main` repeated the arrows beside it. What it added was the worktree that had the branch, and the upstream's name when that differed. A remote branch had its date at the end of its row, which lined up with nothing and was seldom what anyone was looking for.

The arrows were pink and green in an 11-point monospaced font. Everywhere else Roga draws them in gray, on the tabs, in the worktree menu and in the branch row, which turns one orange only when a click would pull or push ([decision 19](0019-pull-and-push-from-the-branch-in-the-title-row.md)). Pink is also the color of conflicts and deleting, so a pink `↓120` beside an old branch read as something wrong with it, where it only said how old the branch was.

Icons sat in a 16-point column with 8 points after them, and each folder or remote moved a row 22 points in. A remote's branches started their names 82 points from the panel's edge and the local ones 60, so the same branch's two rows didn't line up, and long names were cut early.

Nothing said which branches were done with. Of this repository's 16 branches when this was decided, 13 had all their commits in main, and the panel said most of them were up to date. And nothing tied a branch to its remote copy or to the tab of the worktree that has it, other than reading their names.

## Decision

**Every branch is one line**, 28 points tall, as a remote's rows already were. Tags, stashes and submodules keep their second lines, because their names alone don't say what they are.

- **A branch's icon says whose it is and where it's checked out.** The branch checked out here keeps its green branch icon and its checkmark. A branch that another worktree has wears that worktree's tab's icon in place of the branch icon: the worktree icon, or the lock for a locked worktree. Every other local branch has the branch icon. They're all in sky, the color a local branch's name has in history's badges.
- **A remote branch's icon says whether a branch here tracks it**, in that branch's colors: green when it's the upstream of the branch checked out here, sky when another branch tracks it, and gray when none does, as a remote branch's badge is gray in history.
- **After a branch's name** comes a checkmark for the branch checked out here, its counts, or `merged`, or nothing. The counts are `↓` for what its upstream has that it doesn't and `↑` for what it has that its upstream doesn't, in the tabs' gray at 12 points with digits of one width. A branch without an upstream shows only `↑`, for the commits the main branch doesn't have, as its tab does. How far behind main it is goes to its tooltip, since that says how old it is rather than what to do with it.
- **The tooltip has the rest**, on lines of their own after the branch's whole name: where it's checked out, how far it is from its upstream, or that it has none or that its upstream is gone, whether it's merged or else how far it is from main, and when it last changed. A remote branch's says which branches track it, whether it's merged, and when it last changed. VoiceOver reads the same as the row's value.

**A branch whose commits are all in main says `merged`**, and its name goes gray unless a worktree has it checked out. Merged means it has no commits that the main branch, the main branch's upstream or the remote's main branch doesn't, which are the commits Roga already counts a branch ahead against, and that it has moved since it was made. The second part comes from the first line of the branch's reflog, where git writes the commit it was made at, so a branch has moved if its tip is somewhere else now. Once git has expired a reflog's oldest lines, its first line is a move from one commit to another, so that branch has moved too. Without this, a branch just made from an older main, as for a new worktree, would read as merged before its first commit. A remote branch has no reflog of that kind, so it's merged when it has nothing main lacks and isn't on one of the main branch's own commits, the local one, its upstream or the one `origin/HEAD` names. Being behind the local main branch isn't enough, since that can be behind its upstream. A remote's own main branch is never merged.

**The Branches heading has a button that deletes the merged branches** that no worktree has and that aren't checked out here, while there are any. Its tooltip says how many, as in `Delete 8 merged branches…`. It opens decision 38's dialog, titled **Delete merged branches?**, with a switch for each branch, all on, and each saying that its commits are all in main. The dialog takes each branch wherever it is when it opens, since they're on different commits, and leaves out any that are gone. Their commits are all in main, so nothing is lost, and Return deletes them. If something has moved meanwhile so that commits would be lost, the dialog lists them and its button turns red, as for the branches on a commit.

**Icons are smaller and rows move in less.** An icon is drawn at 11 points in a 14-point column with 6 points after it, and each folder moves its rows 16 points in. A remote's branches start where the local ones do rather than a step further in under the remote, so a branch and its remote copy start at the same place, 50 points in.

**Pointing at a branch lights up what goes with it**, once the pointer has rested on the row for 150 milliseconds, so that running it down the list doesn't flash every tab on the way. What lit up stays for 80 milliseconds after the pointer leaves, so moving to the next row doesn't turn it off and on again.

- A local branch tints its upstream's row and lights up the tab of the worktree that has it. A remote branch tints the rows of the branches that track it and lights up the tab of the first of them that a worktree has. Pointing at a tab tints its branch's row.
- A tinted row has the selection's strength in sky, or in green for the branch checked out here and its upstream, so it can't be taken for a selection.
- A tab lights up with a ring in the same color and a soft light around it. It pulses once as it arrives: the ring starts twice as thick, and a second ring spreads 5 points out from it and fades, over 0.8 seconds. Then it holds still, so that it catches the eye across the window without moving at the edge of it, where an agent's ring already turns. The title row clips the tabs 6 points above and below them, so the pulse stays inside that, where a light that swelled further out was cut off and hard to see. With Reduce Motion it's there without the pulse.
- When the row that lights up is out of view, a pill at the top or bottom of the list names it, with an arrow toward it. It takes no clicks, so it never gets in the way of the rows under it.

## Consequences

- The local branches of this repository took 640 of the list's 816 points in the default window, and now take 448, so about seven remote branches are in view under them where one was.
- Loading the panel reads each branch's reflog, but only for branches with nothing ahead of main, and only its first 160 bytes. With refs in a reftable, or with `core.logAllRefUpdates` off, there are no reflog files, and no local branch says merged.
- Remote branches are listed by a `for-each-ref` of their own, which also counts each against main with `%(ahead-behind:)`. Tags are listed apart from them, without counts, because counting each of Linux's tags would be wasted work.
- A branch merged as one squashed commit has commits main doesn't, as git sees it, so it doesn't say merged, though its upstream going after a fetch that prunes says it's gone.
- The panel's counts are gray, so decision 27's green for commits ahead and pink for commits behind no longer appear anywhere in the app. Its colors for added and removed lines are unchanged.
- A submodule's counts are gray too, since they're drawn as a branch's are.
- The tabs and the panel share what the pointer rests on through the model of the worktree on screen. Pointing at a tab while the refs panel is hidden lights up nothing.

## Alternatives considered

- **Two lines for every branch, the second saying what its last commit was about** (B on the canvas). It's the one second line that says something a name can't, but it costs 40 points a branch, which left no remote branch in view in this repository, and a `git log` for each branch as its row scrolls into view.
- **A tab that breathes for as long as the pointer rests on the branch.** It caught the eye as well, but it kept moving at the edge of the window, which the agent's ring already does on the tabs.
- **A steady ring with no pulse.** It's easy to miss when the tab is at the other end of the window from the pointer.
- **Saying merged only when the branch is behind main**, without reading the reflog. Every branch made for a new worktree from an older main would read as merged before its first commit.
