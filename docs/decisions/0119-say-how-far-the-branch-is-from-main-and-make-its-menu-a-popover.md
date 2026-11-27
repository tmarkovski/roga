# 119. Say how far the branch is from main, and make its menu a popover

Accepted on 2026-11-27. This changes the branch row under the tabs from [decision 95](0095-a-repositorys-worktrees-as-tabs.md) and the agent's line in it from [decision 100](0100-say-what-the-worktrees-agent-is-doing-in-the-branch-row.md). The branch's name gets a second line that says how far the branch is from the main branch on the remote, the agent's line becomes two lines, every control in the row becomes 36 points tall, history's number of commits moves into the order's menu, and the branch's menu becomes a popover about the checkout.

## Context

The row didn't say two things that people working in agents' worktrees need. It didn't say how far the branch had drifted from main, which you found out from history or from a merge that went wrong, and it didn't say where the worktree's files are, which showed only at the end of the tab's tooltip. And a click on the branch opened a menu whose first line was the upstream and whose rows were Pull, Push, Fetch, New Branch and Switch Branch, most of which were buttons on the same row and items in the menu bar's Branch menu.

The Branch bar page of the design canvas drew the middle column at 680 and 480 points, in twelve moments and both appearances, with the popovers drawn open and a board to try each option, and the generator is in [`docs/design/branch-bar`](../design/branch-bar). It drew today's row and four options:

- **A** gives the branch and the agent two lines each, with the worktree's folder under the branch.
- **B** shrinks every part to a short label and moves the words into tooltips and popovers.
- **C** keeps A's two lines, but the branch's second line says how far it is from `origin/main`, and the folder moves to the tooltip and the popover.
- **D** is C with every control in the row 36 points tall, and with the branch's icon and the agent's mark in their first lines rather than beside both.

An earlier version of the boards suggested A. That put the folder, which never changes once you know it, in the row, and the distance from main, which changes without you, in the popover, which was the wrong way round. We chose D.

## Decision

**The branch's name has a line under it that says how far the branch is from the main branch on the remote,** as in `4 ahead, 12 behind origin/main`, in 11-point gray words.

- It compares with the remote's branch rather than the local `main`, which goes stale unless someone pulls it, while the fetches Roga makes by itself keep the remote's current.
- The main branch is the one `origin/HEAD` names, or another remote's `HEAD` without origin's, as `RefList.mainBranch` has it. Without a remote's `HEAD`, it's a local `main` or `master`, compared through its upstream when it has one and as it is when it hasn't, as in a repository with no remote.
- How far ahead always shows, since it's how much work the branch holds, and how far behind shows once it isn't zero, as in `4 ahead of origin/main`. A branch with nothing either way reads `Same as origin/main`. Both counts are gray, because in a busy repository every branch is some way behind, and most branches that are behind still merge cleanly.
- **Only a merge that would conflict is orange,** as in `15 behind origin/main · 2 files would conflict`, and that part is never cut. How far ahead gives way to it in the row, and the popover has both. `git merge-tree --write-tree --name-only HEAD origin/main` tries the merge without touching the worktree or the index. git has had it since 2.38, inside Roga's minimum of 2.45 ([decision 8](0008-require-git-2-45.md)). It runs only when the branch and the main branch have both moved on, since otherwise a merge would fast-forward or bring nothing in.
- A branch that's never been pushed adds `· not pushed yet`, and after a fetch that failed, the line says how old its numbers are, as in `· as of 2 h ago`.
- The main branch itself, and a branch whose upstream is the main branch on the remote, have their upstream to compare with, so their line says what the branch's menu used to start with, as in `origin/main · up to date · fetched 4 min ago`.
- A detached `HEAD` reads `Not on a branch`, a branch without commits reads `No commits yet`, and a locked worktree has a small lock before the words.
- The tooltip has the worktree's folder, then the upstream's line.

`MainDistanceLoader` finds the main branch with one `git for-each-ref` of the remotes' `HEAD`s and a local `main` and `master`, reads where it and `HEAD` are with `git rev-parse`, and when neither has moved since last time, returns what it said then, so a look that changed nothing runs no merge. Otherwise it counts with `git rev-list --left-right --count`. It runs at utility priority, apart from the look that asked, so a slow merge can't hold up history or the counts, and with `GIT_NO_LAZY_FETCH`, so that in a partial clone that hasn't got the files' contents it says nothing about conflicts rather than downloading them.

**The branch's icon and the agent's mark sit in their first lines, at 13 points,** the size of the text beside them, where the branch's chip drew its icon at about 15. Smaller than 12, the icon's two circles and curve run together. A column beside both lines treated them as more than they are: the icon is always the branch's, as the chip drew it even for a detached `HEAD`, whose hash and `detached` already say what it is, and the mark's color already carries the agent's state. With both in their first lines, the second lines start at the blocks' left edges, which gives the agent's words about 24 more points.

**The agent's line becomes two lines:** who and what state, with how long, over what it's doing, as in `Claude Code is working · 6 min` over `Run the test suite`. The first line is in the text's color, amber after the amber circle while an agent waits for you, as in `Claude Code needs approval` over `git push`, and red after a red cross for a turn that ended with an error. Two agents read `Claude Code and Codex are working`, and more read `3 agents are working`. When another session is doing something else, the second line says so after its words, as in `git push · Claude Code is working`. While an agent works, decision 100's light runs through the second line, with no mark before the first, because the worktree's tab turns its ring a few points above. When the row is short of room, the second line is cut first, then the first gives way to the agent's name, as in `Claude Code · 6 min`, which stays whole, and then the line under the branch's name is cut.

**Every control in the row is 36 points tall:** the branch, the counts, a worktree stuck partway, the agent's lines, Fetch, New Branch and the order. The row drew them all at 32, so the gray that fills a control under the pointer was the same height from one end to the other. The two-line blocks need 36, and in 32 they'd have about 2 points above and below their text. At 36, the counts between them would otherwise be 4 points shorter than their neighbours, which reads as a misalignment as the pointer slides along the row, and a click target that shrinks partway. Each control has 4 points above and below in the row's 44. The panels' headers keep their 32-point buttons, since they're a different row.

**History's number of commits moves into the order's menu,** as its first line, `History shows 1,234 commits`. The agent's lines take the room it shared with them.

**A press on the branch opens a popover about the checkout** ([decision 111](0111-open-popovers-on-the-press-as-menus-do.md)), 400 points wide, with what the row has no room for:

- the branch's name, with a button that copies it, and whether this is the main worktree or a linked one, as in `A worktree of roga`,
- the folder, with **Show in Finder**, **Open in Terminal**, in the terminal chosen in Settings › General, and **Copy Path**,
- for a locked worktree, the lock's reason and **Unlock**, which takes it off at once, as the sidebar's does ([decision 116](0116-offer-to-delete-a-locked-worktree-anyway.md)),
- the upstream, how far the branch is from it and when Roga last fetched, or `Not pushed yet`,
- the main branch, as in `4 ahead, 15 behind origin/main`, over `Merging it would conflict in LoginView.swift and LoginStore.swift` in orange, or `origin/main has 12 commits this branch doesn't`, with **Rebase onto origin/main** and **Merge origin/main** while it has commits the branch doesn't, which ask first, as the refs panel's menu does,
- **Switch Branch…**, which opens the refs panel's filter, and for a detached `HEAD`, **New Branch Here…**.

Pull, Push, Fetch and New Branch aren't in it, since they're on the row and in the menu bar's Branch menu with their shortcuts, and that menu doesn't change. A `↑` that git would reject still opens that menu's rows, since it says what can be done instead.

## Consequences

- How far an agent's worktree has drifted from main shows while it drifts, and a merge that would conflict shows before anyone tries it.
- The row has two kinds of ahead and behind: the arrows against the upstream and the words against the main branch. They're meant to read apart because they look and behave differently: the arrows are orange buttons that pull and push and go away when there's nothing to do, and the words are gray, and a click on them opens the popover rather than doing anything to the branch. If people still mix them up, the words could name `main` and leave `origin/` to the popover.
- `git merge-tree` writes the objects the merge would make to the repository, as any merge does. Nothing refers to them, so `git gc` clears them in time, and the same merge writes nothing new.
- How quickly `git merge-tree` runs on a large repository hasn't been measured against the benchmark repositories yet. It runs only when both sides have moved on, only once for each pair of commits, and apart from what someone waits for, but a slow one would still use a core after each fetch for each worktree on screen. It needs measuring before a release.
- The folder is in the tooltip and the popover rather than the row, next to what you'd do with it.
- **Rename Branch…**, which the boards drew at the popover's foot, isn't built. Renaming a branch that has an upstream has to decide what becomes of the upstream and of its name on the remote, which is a decision of its own.
- The boards drew a turning ring before a working agent's first line. The row keeps decision 100's light instead, for the reason decision 100 gives.

## Alternatives considered

- **A, the folder under the branch.** The folder never changes once you know it, and you need it mostly to do something there, which the popover's buttons are for.
- **B, short labels with the words in tooltips.** It's the quietest, but what the agent is doing would again take a hover and a wait, which is what decision 100 set out to fix.
- **C, at the row's old heights.** Its two-line blocks need 36 points, so the counts between them were 4 points shorter than their neighbours.
- **Cards that open on hover** rather than popovers. macOS tooltips can't hold a button, and a card that opened on hover would open as the pointer crosses the row to Fetch, couldn't be reached from the keyboard or with VoiceOver, and would close when the pointer left it, which makes Open in Terminal inside it hard to click.
- **Comparing with the local `main`.** It goes stale unless someone pulls it, so a branch would look up to date with a main that's hours old.
- **Orange whenever the branch is behind,** or when it's far behind. In a busy repository that's every branch, so the orange would stop being read within a week, and the count already says how far.
