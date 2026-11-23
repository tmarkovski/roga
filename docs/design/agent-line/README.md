# Agent line

Boards for where the window could say what the agent in the worktree on screen is doing. They're on the Agent line page of the design canvas [yaga layout options](https://claude.ai/artifact/4WQVua6gwKqSBoiRdf2FhX), and [`boards.py`](boards.py) draws every board.

[Decision 95](../../decisions/0095-a-repositorys-worktrees-as-tabs.md) turned the sidebar's worktrees off by default, so a repository's row speaks for its most urgent worktree, which may not be the one on screen. The line from [decision 47](../../decisions/0047-say-what-an-agent-is-doing-in-a-line-the-helper-makes.md) that says what this worktree's agent is doing now shows only in its tab's tooltip. The boards draw the middle column at its real sizes, 680 points wide in the default window of 1280 with the sidebar and the refs panel showing, and 480 points in a narrower one:

- **Today**, with the tab's tooltip open.
- **A** puts the line after the branch's counts, where Roga already says what just happened, as a button that opens a popover.
- **A2** puts the same line in a pill centered between the two ends of the branch row, as Xcode's toolbar shows its activity.
- **B** adds a strip under the branch row for each session, with room for the agent's name, its whole line, its subagents and buttons.
- **C** writes the line on history's row for uncommitted changes, whose dot becomes the agent's mark.
- **A+C** is A, plus the agent's mark in place of the dot on the row for uncommitted changes while the agent works or waits.
- **A+S** is A, plus a light in Roga's orange running through that row's words while the agent works.

After those come every option in fifteen moments, in both appearances, then the popover behind A's line with a section for each session, and a board that plays one worktree's story in whichever option, width and view of history you pick. The last three moments, with no uncommitted files, the panels maximized and history scrolled down, are where A and C part.

## Decided

- **A+S.** Decided on November 23, 2026, as [decision 99](../../decisions/0099-say-what-the-worktrees-agent-is-doing-in-the-branch-row.md), which isn't built yet. A fills room the branch row already leaves empty, costs no height, and keeps saying what the agent is doing whether or not there are uncommitted files, with history scrolled, and with the panels maximized over history, where C's line is out of view. A+C's mark was left out because a working agent would then turn in three places a few points apart, and the shimmer ties the row to the agent without a third mark.
- **Show Terminal is left out of the popover**, which the canvas still draws. It would need new code to bring forward the app the agent's process runs in, and it couldn't pick the tab.

## Still to decide

- **How long a finished reply stays.** Decision 99 keeps it in the row until the agent's next turn, and says it could go once the worktree has been on screen for a while if that turns out to be stale.
- **A short history of the agent's last lines in the popover.** It would need `AgentMonitor` to keep them.

## Regenerating the boards

Read `project/canvas.json` from the canvas into a folder first, so that the merge starts from what's live, then:

```bash
uv run docs/design/agent-line/boards.py --out <folder> --canvas <folder>/project/canvas.json
```

It writes the `Al-*.dc.html` boards into `<folder>/project/` and replaces the Agent line page's boards and notes in that `canvas.json`, leaving every other page alone. Publish those files to the canvas.
