# Branch bar

Boards for what the row under the tabs could say and how it could say it. They're on the Branch bar page of the design canvas [yaga layout options](https://claude.ai/artifact/4WQVua6gwKqSBoiRdf2FhX#page-branchbar), and [`boards.py`](boards.py) draws every board.

The row comes from [decision 95](../../decisions/0095-a-repositorys-worktrees-as-tabs.md), and [decision 100](../../decisions/0100-say-what-the-worktrees-agent-is-doing-in-the-branch-row.md) added the agent's line to it. Two things about it prompted these boards. It never says where the worktree's files are, which shows only at the end of the tab's tooltip, although that folder is what tells two checkouts of one repository apart and what you'd paste into a terminal. And a click on the branch opens a menu whose first line is the upstream and whose rows are Pull, Push, Fetch, New Branch and Switch Branch, most of which are buttons on the same row and items in the menu bar's Branch menu.

The boards draw the middle column at 680 points, as in the default window, and at 480, with Claude Code running the tests in `agent/fix-login`:

- **Today**, for comparison.
- **A · Two lines** gives the branch and the agent two lines each in the row's 44 points, as a window's title and subtitle share a toolbar. The folder sits under the branch, cut in its middle so that its last part stays. The agent's state and how long sit over what it's doing, as in `Claude Code is working · 6 min` over `Run the test suite`, and the light runs through the second line.
- **B · Labels** shrinks every part to a short label, the folder's last part, the branch, the counts and the agent's name and time, and moves the words into tooltips and popovers.
- **C · Against main** is A with the branch's second line saying how far it is from main, as in `4 ahead of main · 12 behind`, with the folder in the tooltip and the popover.

In A, B and C the number of commits moves into the order's menu, which leaves the agent the room it shared with it, and the branch's menu becomes a popover about the checkout:

- the branch's name, with a button to copy it, and whether this is the main worktree or a linked one,
- the folder, with Show in Finder, Open in Terminal and Copy Path,
- the lock's reason and Unlock, for a locked worktree,
- the upstream, how far the branch is from it, and when Roga last fetched,
- how far the branch is from main, with Rebase onto main and Merge main while main has commits it lacks, which Roga doesn't work out today,
- Switch Branch… and Rename Branch….

Pull, Push, Fetch and New Branch aren't in it, since they're on the row and in the menu bar with their shortcuts. The agent's popover is decision 100's.

After those come every option in ten moments, in both appearances, the popovers drawn open, and a board to try every option and moment, where a click opens a popover and a hover shows the tooltip after macOS's delay.

## Suggested

**A, with the branch's popover.** It says more without making the row taller, which decision 100 avoided because a taller row pushes history down. The agent's name over its line says whose words they are, which a bare `git push` didn't, and the folder sits where you look for the branch. B is the quietest, but what the agent is doing would again take a hover and a wait, which is what decision 100 set out to fix. C's distance from main changes as main moves rather than as you work, so it fits the popover better than the row.

## Click or hover

The boards keep the detail behind clicks, with a tooltip on every part for a quick look. macOS shows tooltips on hover, after about a second, and they can't hold a button. Anything with buttons is a popover that opens on a click, on the press (decision 111). A card that opened on hover would open as the pointer crosses the row to Fetch, couldn't be reached from the keyboard or with VoiceOver, and would close when the pointer left it, which makes Open in Terminal inside it hard to click.

## Still to decide

- **Which second line, A's or C's.** A's folder is calm and never changes. C's distance from main is more useful in an agent's worktree that has been running a while.
- **Whether how far main has moved belongs in the row at all,** as a count after `↑`, while it's large enough to matter. It would need a click to do something that's safe, and a rebase isn't.
- **Where main is.** The popover compares with `main`. A repository whose default branch has another name, or a branch made from another branch, would need the base Roga already uses to count a never-pushed branch's `↑` (decision 95).
- **Which terminal Open in Terminal uses.** Opening a new window at a folder is simpler than decision 100's Show Terminal, which had to find the window an agent runs in, but it still has to know whether the user runs Terminal, iTerm or Ghostty.

## Regenerating the boards

Read `project/canvas.json` from the canvas into a folder first, so that the merge starts from what's live, then:

```bash
uv run docs/design/branch-bar/boards.py --out <folder> --canvas <folder>/project/canvas.json
```

It writes the `Bb-*.dc.html` boards into `<folder>/project/` and replaces the Branch bar page's boards and notes in that `canvas.json`, leaving every other page alone. Publish those files to the canvas.
