# 48. A second line under a sidebar row while there's something to say

Accepted on 2026-11-06. Partly supersedes [decision 16](0016-a-rail-of-organizations-in-the-sidebar.md), whose rows are always one line 32 points tall, and [decision 41](0041-agents-status-from-their-hooks-and-messages-from-their-clis.md), which puts an agent's mark before a row's count. A row now grows a second line while an agent is at work, waits for you or has finished, or while its worktree stopped partway through a merge, a rebase or a revert, and an agent's mark starts that line. The line is the one [decision 47](0047-say-what-an-agent-is-doing-in-a-line-the-helper-makes.md) has the helper make, and stopped work is said as [decision 28](0028-show-a-worktree-thats-stuck-partway.md) says it in the title row.

## Context

Decision 16 took the sidebar's rows to one line so that nearly twice as many fit in a window. The second line it dropped was each worktree's folder, which mostly repeated the branch. Decision 41 then marked the rows where agents were at work, and decision 47 gave each agent a short line about what it's doing. That line only showed in the mark's tooltip and in the worktree menu, so someone watching agents in three worktrees had to hover over each row in turn and wait for its tooltip.

The design canvas's Second line page drew four ways to show it, with the same made-up organization in a window 860 points tall: today's rows, two lines on every row (A), a second line only while there's something to say (B), and B with the mark left before the count (B2). A clickable board simulated agents starting, asking, finishing and quitting, so the rows could be seen moving. Boards C and S5 on the canvas's earlier pages had drawn a second line with "writing now" in it, before decision 16. We chose B.

## Decision

**A row grows a second line while there's something to say,** and is 48 points tall rather than 32. Quiet rows stay one line, so a list with a few agents at work still fits about as well as before. On the canvas, 17 rows with six of them saying something take 672 of the 776 points the window has for the list, where two lines on every row took 848.

- The first line stays where it is in a one-line row. The second, at 13 points, starts 25 points down, so the two lines sit 7 points from the row's top and bottom edges. It starts where the row's own text does, under the branch or the repository's name.
- The count and the row's commands stay at the top right, beside the first line. The second line runs under them and ends where a count does, because the line needs the room more than they do. The boards stopped it short of the count, which in a worktree's row at the default width cut "git push" down to "gi…".
- The fill of a selected or hovered row covers both lines.
- The line down a repository's worktrees turns toward the last one's first line rather than the middle of its row, so it still meets the branch when that row has two lines.

**What the line says, when more than one thing applies:**

1. An agent waiting for you, because it can't go on until you answer.
2. A merge, rebase or revert that stopped partway, as the title row says it: `Rebasing main · 2 conflicts` in red, or `Rebasing main · ready to continue` in gray. Only what's underway is cut short, at its end, so that the conflicts stay in sight.
3. An agent at work, or one that finished and nobody has seen yet.

A waiting agent goes before a rebase that stopped because the rebase will still be there afterward, and the count in red with its triangle still says there are conflicts.

**An agent's line starts with its mark,** 5 points before its words, and that mark is no longer before the count. Since the mark already says an agent is speaking, one session's line is its own words without its name: `Run the test suite · 6 min`, `Needs your OK: git push · 2 min`, `Wants a plan approved · 2 min`, or the first line of a finished agent's reply. Decision 47 named the agent in the worktree menu so that a bare "git push" couldn't read as something Roga is doing. Here the mark does that.

- Before an agent has said anything, or when several sessions share a worktree, the line names them: `Claude Code is working`, `Codex needs your OK`, `2 agents working · 6 min`, `2 agents are waiting for you` or `3 agents finished`.
- It's amber while the agent waits, and gray otherwise. How long shows from a minute on, as in the tooltip, and never for an agent that finished. The words are cut short at their end, and how long stays whole.
- The line's tooltip is the mark's, which names the agent and has the whole line.
- While the line is about stopped work, an agent at work or one that finished keeps its mark before the count, as before.

**Which rows have one.** A repository's row speaks for its main worktree, as its mark did. The row for a collapsed repository's hidden worktrees speaks for the most urgent agent among them, and not for their stopped work, which its red count already shows. **Deleting…** and **Folder missing** stay at the right of the first line, since they're about the row itself.

**Show agents in the sidebar,** on the Agents page in Settings, turns off agents' lines as it turns off their marks. Stopped work still shows, because that's Roga's own.

**A row's height changes at once, without an animation.** Animating one row's height doesn't carry the rows under it along, so they would jump while it grew. Animating the whole list together would mean the list reads every agent's state, which decision 47 kept to the rows that show a mark, so that a new line redraws only those.

## Consequences

- The list moves while agents work. A row grows when an agent starts, and shrinks once its finish is seen or the agent quits, and every row under it shifts by 16 points, sometimes under the pointer. If that turns out to be too busy, a row could keep its height until the pointer leaves the sidebar.
- A long list with many agents at work shows fewer rows than one-line rows did, though more than two lines on every row would.
- The sidebar now says when a worktree stopped partway, which only the title row and the worktree menu said before. It comes from the same look that counts uncommitted files, so it runs no more git.
- With two sessions in one worktree and one of them waiting, the line is the waiting one's words, as the tooltip is, and doesn't say that another is at work there.
- The row for hidden worktrees doesn't say which of them its line is about. Expanding the repository shows it.
- At the sidebar's default width, a worktree's row still cuts the end off a line as long as `Needs your OK: git push · 2 min`, to `Needs your OK: git… · 2 min`. A wider sidebar or the tooltip shows it whole.
- VoiceOver reads stopped work as part of the row, along with the agent's description it already read.
- The generator for the canvas's Second line page is in [`docs/design/second-line/`](../design/second-line/).
