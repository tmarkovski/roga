# Branch list

Boards for how the refs panel could show branches. They're on the Branches page of the design canvas [yaga layout options](https://claude.ai/artifact/4WQVua6gwKqSBoiRdf2FhX#page-branches), and [`boards.py`](boards.py) draws every board.

Today a local branch takes two lines while folders, remotes and a remote's branches take one. Most of the second line repeats the row: `up to date with origin/tm/commit-box-composer` restates the branch's own name, and `1 ahead, 120 behind main` repeats the arrows beside it. The arrows are pink and green in a monospaced font, where the tabs, the worktree menu and the branch row draw them in gray, with orange only for a click that would pull or push ([decision 19](../../decisions/0019-pull-and-push-from-the-branch-in-the-title-row.md)). Icons sit in a 16-point column with 8 points after them, and each folder or remote moves its rows 22 points in, so a remote's branches start their names 82 points from the panel's edge.

The boards draw this repository's own branches as they stood on 27 November 2026, in a window 860 points tall:

- **Today**, in both appearances.
- **A** gives every row one line. A branch that another worktree has wears that worktree's icon, or the lock its tab has. The counts are gray. A branch whose commits are all in main says **merged**, and its name goes gray unless a worktree has it. The icon's color says whose a branch is, as history's badges do ([decision 23](../../decisions/0023-one-badge-for-a-branch-and-its-upstream.md), [decision 27](../../decisions/0027-give-the-graph-and-branches-monokais-colors.md)): green for the branch checked out here, sky for the rest of yours, and on a remote, sky for a branch one of yours tracks and gray for one nobody here does. The rest, including a remote branch's date, moves to the tooltip. Icons go to 12 points in a 14-point column with 6 after them, folders indent 16 points, and a remote's rows aren't indented under the remote, so a branch and its remote copy start at the same place.
- **B** is A with a second line on every branch, local or remote, saying what its latest commit that isn't a merge was about.

After those come every state a row can be in, as today and as A in both appearances, how ahead and behind look in each place Roga shows them, four moments of what pointing at a branch lights up, and a board to try it.

## Decided

- **A, with one pulse, and remote branches say merged too.** Decided on November 27, 2026, as [decision 119](../../decisions/0119-branches-on-one-line-and-what-the-pointer-lights-up.md). Every item under Proposed below went in together. The app draws a row's icon at 11 points in a 14-point column, where the boards draw it at 12 in 14, and its counts and pill use the `↓` and `↑` characters, as the boards do.

## Proposed

- **Gray counts**, at 12 points with digits of one width, as on the tabs. How far a branch is behind main leaves the row for its tooltip, since it says how old the branch is rather than what to do with it. A branch without an upstream shows `↑` for the commits no remote has, as its tab does.
- **Merged**, when every commit on a branch is in main, main's upstream or the branch `origin/HEAD` names, and the branch has moved since it was made. The second part comes from the first line of the branch's reflog, so that a branch just made from an older main doesn't read as merged before its first commit. A reflog whose oldest lines git has expired starts with a move, which counts as having moved. `git for-each-ref` counts every branch against main in one run with `%(ahead-behind:main)`. A button on the Branches heading deletes the merged branches that no worktree has, through [decision 38](../../decisions/0038-one-delete-on-a-commit-with-its-branches-in-the-dialog.md)'s dialog. Of this repository's 16 branches, 13 are merged.
- **One line for every row**, as A draws it.
- **Pointing at a branch** tints its remote copy, or the local branch for a remote one, in sky, or green for the branch checked out here, and lights the tab of the worktree that has it with a ring and one pulse. Pointing at a tab tints its branch. When the other row is scrolled out of view, a pill at the edge of the list names it and points to it. In the app the link would wait until the pointer has rested on a row for about 150 milliseconds, and Reduce Motion gets the ring without the pulse.
- **Smaller icons and indents**, as A draws them.

Each of these can land on its own.

## Still to decide

- **Squash merges.** A branch merged as one squashed commit looks unmerged to git, so it doesn't say merged. Its tooltip does say when its upstream is gone after a fetch that prunes, which is often the only sign. Saying merged then would need its own decision.
- **The branch row's distance from main.** The Branch bar page on the same canvas draws a second line under the branch's chip that says how far the branch is from main, in orange when main has commits the branch lacks. These boards treat behind main as a branch's age and leave it out of the panel's rows, so the two should agree on what behind main means before either is built.

## Regenerating the boards

Read `project/canvas.json` from the canvas into a folder first, so that the merge starts from what's live, then:

```bash
uv run docs/design/branch-list/boards.py --out <folder> --canvas <folder>/project/canvas.json
```

It writes the `Br-*.dc.html` boards into `<folder>/project/` and replaces the Branches page's boards and notes in that `canvas.json`, leaving every other page alone. Publish those files to the canvas. The icons come from [`../icons/`](../icons/), so they're the app's own.
