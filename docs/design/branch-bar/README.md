# Branch bar

Boards for what the row under the tabs could say and how it could say it. They're on the Branch bar page of the design canvas [yaga layout options](https://claude.ai/artifact/4WQVua6gwKqSBoiRdf2FhX#page-branchbar), and [`boards.py`](boards.py) draws every board.

The row comes from [decision 95](../../decisions/0095-a-repositorys-worktrees-as-tabs.md), and [decision 100](../../decisions/0100-say-what-the-worktrees-agent-is-doing-in-the-branch-row.md) added the agent's line to it. Two things about it prompted these boards. It doesn't say how far the branch has drifted from main, which you find out from history or from a merge that goes wrong, and it doesn't say where the worktree's files are, which shows only at the end of the tab's tooltip. And a click on the branch opens a menu whose first line is the upstream and whose rows are Pull, Push, Fetch, New Branch and Switch Branch, most of which are buttons on the same row and items in the menu bar's Branch menu.

The boards draw the middle column at 680 points, as in the default window, and at 480, with Claude Code running the tests in `agent/fix-login`:

- **Today**, for comparison.
- **A · Two lines** gives the branch and the agent two lines each in the row's 44 points, as a window's title and subtitle share a toolbar. The folder sits under the branch, cut in its middle so that its last part stays. The agent's state and how long sit over what it's doing, as in `Claude Code is working · 6 min` over `Run the test suite`, and the light runs through the second line.
- **B · Labels** shrinks every part to a short label, the folder's last part, the branch, the counts and the agent's name and time, and moves the words into tooltips and popovers.
- **C · Against main** keeps A's two lines, but the branch's second line says how far it is from `origin/main`, and the folder moves to the tooltip and the popover.
- **D · C at one height** is C with every control in the row 36 points tall, as its two-line blocks are, and with the branch's icon and the agent's mark in their first lines rather than beside both.

In A to D the number of commits moves into the order's menu, which leaves the agent the room it shared with it, and the branch's menu becomes a popover about the checkout:

- the branch's name, with a button to copy it, and whether this is the main worktree or a linked one,
- the folder, with Show in Finder, Open in Terminal and Copy Path,
- the lock's reason and Unlock, for a locked worktree,
- the upstream, how far the branch is from it, and when Roga last fetched,
- how far the branch is from `origin/main`, which files a merge of it would conflict in, and Rebase and Merge while it has commits the branch lacks,
- Switch Branch… and Rename Branch….

Pull, Push, Fetch and New Branch aren't in it, since they're on the row and in the menu bar with their shortcuts. The agent's popover is decision 100's.

After those come a board that compares how tall each control's fill is, every option in twelve moments, in both appearances, the popovers drawn open, and a board to try every option and moment, where a click opens a popover and a hover shows the tooltip after macOS's delay.

## Suggested

**C, with the branch's popover.** The row should hold two kinds of things: what you can do, like the counts that pull and push, and what changed without you, like the agent's work and main moving on. Everything else goes in the popover.

The folder never changes once you know it, and you mostly need it to do something there, so it belongs beside Open in Terminal in the popover, with the tooltip for a quick look. How far `origin/main` has moved is the opposite. Nobody notices it until a merge goes wrong, and an agent's worktree that has been running for an hour is exactly where it drifts. A, which an earlier version of these boards suggested, put the static folder in the row and the changing distance in the popover, which was the wrong way round.

A number that changes isn't worth showing on its own, though. In a busy repository every branch is always some way behind, and most branches that are behind still merge cleanly, so a count that's always orange would stop being read within a week. C's line is drawn to stay quiet until it matters:

- **It compares with `origin/main`, not the local `main`.** The local `main` goes stale unless someone pulls it, while the fetches Roga makes on its own keep `origin/main` current.
- **How far ahead always shows,** as in `4 ahead of origin/main`, since it's how much work the branch holds. **How far behind shows once it isn't zero,** as in `4 ahead, 12 behind origin/main`. Both are gray.
- **Only a merge that would conflict is orange,** as in `15 behind origin/main · 2 files would conflict`, and that part is never cut. `git merge-tree --write-tree origin/main HEAD` says so without touching the worktree, and git has had it since 2.38, inside Roga's minimum of 2.45 (decision 8). How far ahead gives way to it in the row, and the popover still has both.
- **After a fetch that failed,** the line says how old its numbers are, as in `· as of 2 h ago`.

For `main` itself the line says how far it is from `origin/main` and when Roga last fetched, and for a detached HEAD it says it isn't on a branch.

B is the quietest option, but what the agent is doing would again take a hover and a wait, which is what decision 100 set out to fix.

## One height for the row

Today's row draws every control at 32 points: the branch's chip, the counts, the agent's line, and the icon buttons, Fetch, New Branch and the order. So the gray that fills a control under the pointer is the same height from one end of the row to the other. C's two-line blocks need 36 points, which leaves the counts between them 4 points shorter than their neighbours, and that reads as a misalignment as the pointer slides from the branch to `↑2` to the agent. The fills also mark where a click lands, so a steady height means the pointer doesn't drop into a smaller box partway along the row.

D raises every control in the row to 36 points, which leaves 4 points above and below each fill in the 44-point row. The icon button style already takes a size. Squeezing the two-line blocks into 32 points instead would leave about 2 points above and below their text, which looks cramped beside the single-line buttons. The tabs in the row above stay at 32, since they're a different kind of control in a different row.

An earlier version of these boards drew the counts at 28 points, where the app draws them at 32. They're 32 in every option now.

D also moves the branch's icon into the first line, before the name, as today's chip draws it, and the agent's mark before its state. Both are 13 points, the size of the text beside them, where today's chip draws the icon at about 15. Smaller than 12, the icon's two circles and curve run together, and each point it loses gives only a point back to the line. A and C give each a 16-point column beside both lines, which treats them as more than they are. The icon is always the branch's, since the app draws it even for a detached HEAD, whose hash and the word `detached` already say it, and the mark's color already carries the agent's state. With both in their first lines, the second lines start at the blocks' left edges, which gives the agent's words about 24 more points before they're cut. The second line's text starts a little left of the first line's, while the block's left edge stays straight.

## What to watch in C

The row now has two kinds of ahead and behind: the arrows against the upstream, and the words against `origin/main`. They're meant to read apart because they look and behave differently. The arrows are orange buttons that pull and push and go away when there's nothing to do. The words are gray, and a click on them opens the branch's popover rather than doing anything to the branch. If people still mix them up, the words could name `main` and leave `origin/` to the popover.

## Click or hover

The boards keep the detail behind clicks, with a tooltip on every part for a quick look. macOS shows tooltips on hover, after about a second, and they can't hold a button. Anything with buttons is a popover that opens on a click, on the press (decision 111). A card that opened on hover would open as the pointer crosses the row to Fetch, couldn't be reached from the keyboard or with VoiceOver, and would close when the pointer left it, which makes Open in Terminal inside it hard to click.

## Built

D is built, as [decision 120](../../decisions/0120-say-how-far-the-branch-is-from-main-and-make-its-menu-a-popover.md) describes, and it settled what these boards left open:

- **Which branch is main.** It's the one `origin/HEAD` names, or another remote's `HEAD`, or else a local `main` or `master` through its upstream. A branch whose upstream is that branch says what its upstream is, as `main` does.
- **Orange without a conflict.** There's none, however far behind the branch is, since the count already says it.
- **Which terminal Open in Terminal uses.** It's the one chosen in Settings › General, which the sidebar's Open in Terminal already uses.
- **A working agent's mark.** The boards drew a turning ring before its first line. The app keeps decision 100's light in the second line instead, because the worktree's tab turns a ring a few points above.
- **What Rename Branch… does to the upstream.** Nothing: it renames the branch here only, the branch keeps tracking its upstream, which keeps its name on the remote, and `↑` pushes to that by name.

One thing is still open. How quickly `git merge-tree` runs on large repositories hasn't been measured against the benchmark repositories, though it only runs when both sides have moved on, once for each pair of commits, and apart from anything someone waits for.

## Regenerating the boards

Read `project/canvas.json` from the canvas into a folder first, so that the merge starts from what's live, then:

```bash
uv run docs/design/branch-bar/boards.py --out <folder> --canvas <folder>/project/canvas.json
```

It writes the `Bb-*.dc.html` boards into `<folder>/project/` and replaces the Branch bar page's boards and notes in that `canvas.json`, leaving every other page alone. Publish those files to the canvas.
