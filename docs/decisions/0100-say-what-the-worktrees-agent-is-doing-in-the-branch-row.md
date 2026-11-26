# 100. Say what the worktree's agent is doing in the branch row

Accepted on 2026-11-23. This adds a line to the branch row under the tabs from [decision 95](0095-a-repositorys-worktrees-as-tabs.md) that says what the agent in the worktree on screen is doing, in the words of [decision 48](0048-a-second-line-under-a-sidebar-row-while-theres-something-to-say.md)'s second line, with a popover that has a section for each session. While the agent works, [decision 68](0068-mark-an-agents-commands-with-an-orange-line-rather-than-sparkles.md)'s light runs through the line's words. Amended in place on 2026-11-26: the light runs through the agent line's words in place of its turning ring, rather than through the words of history's row for uncommitted changes ([decision 15](0015-uncommitted-changes-as-a-row-in-history.md)). The line's ring turned a few points under the worktree tab's own ring and said the same thing, and the shimmer on history's row was a third sign of one agent at work. Version 0.0.9 shipped with the ring and the shimmer on history's row.

## Context

Decision 95 put a repository's worktrees in tabs and made the sidebar's worktree rows a choice that starts off. With it off, a repository's row and its second line speak for the most urgent of its worktrees, which may not be the one on screen. The tab's mark says that an agent is working, waiting or finished, but what it's doing shows only in the tab's tooltip, after a hover and the tooltip's delay. So the line from [decision 47](0047-say-what-an-agent-is-doing-in-a-line-the-helper-makes.md) was easiest to see for the worktrees you weren't looking at.

The branch row has room for it. In the default window, 1280 points wide with the sidebar (312) and the refs panel (288) showing, the middle column is 680 points wide, and about 240 of them between the branch's counts and Fetch are empty, except for the few seconds when Roga says what just happened ([decision 76](0076-keep-the-counts-in-view-while-the-title-row-says-what-happened.md)).

The Agent line page of the design canvas drew the middle column at its real sizes, at 680 and 480 points, and the generator is in [`docs/design/agent-line`](../design/agent-line). It drew today's window and six options, each in fifteen moments in both appearances, then a popover and a board that plays one worktree's story in any of them:

- **A** puts the line after the branch's counts.
- **A2** puts it in a pill centered between the two ends of the branch row.
- **B** adds a strip under the branch row for each session.
- **C** writes it on history's row for uncommitted changes, whose dot becomes the agent's mark.
- **A+C** is A, with C's mark on that row.
- **A+S** is A, with a light running through that row's words while the agent works.

We chose A+S.

## Decision

**The branch row says what the worktree's agent is doing, after the counts.** It's the agent's words and how long, as in `Run the test suite · 6 min`, after a mark 6 points before them unless the agent is at work. The words are those of the sidebar's second line:

- An agent at work is in gray, with no mark before it, as in `Run the test suite · 6 min`, and one that hasn't said anything yet is named, as in `Claude Code is working`. A light in Roga's orange runs left to right through the words about every two and a half seconds, as decision 68's light runs along a line while an agent writes. It's there rather than [decision 46](0046-turn-the-ring-of-an-agent-at-work.md)'s turning ring, because the worktree's tab turns that ring a few points above. The light stops under Reduce Motion and while the window is hidden, as the ring stops, and then the tab's ring still marks the agent.
- An agent that waits for you is in amber, after the amber circle, as in `Approval required: git push · 2 min` and `Wants a plan approved · 4 min`.
- Several sessions in the worktree read `2 agents working · 6 min`. When others are doing something else, the line names the agent it's about, as the worktree menu does, as in `Codex needs approval: git push · 1 min`.
- How long shows from a minute on, and never for an agent that finished.
- A finished agent shows the first line of its reply in gray, after a gray check in a circle rather than the blue dot, because the worktree on screen counts as seen at once and its tab never shows the dot. It stays until the agent starts another turn or its session ends. A turn that ended with `StopFailure` reads `Claude Code stopped with an error`, after a red cross in a circle, since `StopFailure` leaves no line.
- With no session, an idle one, or **Use agents** off ([decision 89](0089-one-switch-for-agents.md)), there's nothing, and the row is as it was.

**Roga's own words come first.** While the row says what just happened, as `Committed 9f2c1ab` with Undo, or the house works beside `Pulling…`, the agent's line steps aside, and it comes back once they close. The tab's mark still says the agent is there. When the worktree is stuck partway, as in `⚠ Rebasing main · 2 conflicts`, the agent's line follows those words, which stay whole.

**When the row is short of room,** the agent's words are cut at their end first, and its mark and how long stay. The light is cut to the words as they're drawn, so it never runs past the ellipsis. Then history's number of commits goes, and then the branch's name is cut short, as decision 95 has it. With a middle column under about 600 points, history's number goes as soon as the agent has something to say.

**The line is a button.** It fills with gray under the pointer, as the row's other buttons do, its tooltip is the mark's from decision 47, and a click opens a popover that hangs from it ([decision 83](0083-open-a-new-refs-popover-where-it-was-asked-for.md)). VoiceOver reads the agent's state and its line, as it does on a sidebar row.

**The popover has a section for each session,** in the order the sidebar ranks them, with a waiting one first. A section has the agent's mark, its name, what it's doing in a word or two, such as Working, Approval required, Waiting for you or Finished, and how long, then its whole line, up to 120 characters on two lines, then how many subagents are running, if any. At its foot, **Review 3 Files** selects history's row for uncommitted changes, while there are any.

**The popover's sections keep their marks,** the turning ring among them, since each names its own agent and the popover hangs away from the tabs.

**History's row for uncommitted changes doesn't change.** It keeps its dot and its gray words ([decision 86](0086-gray-the-words-of-the-uncommitted-row.md)) while an agent works.

**The branch row reads the line only for the worktree it shows.** Decision 47 keeps the line apart from the marks so that a new line redraws only the rows that show it, and this keeps that: a new line redraws the branch row and nothing else.

## Consequences

- What the worktree's agent is doing stays in view whatever history shows: with no uncommitted files, with history scrolled, and with the panels maximized, which leave the branch row in place ([decision 52](0052-maximize-or-minimize-the-panels-under-history.md)).
- A working agent shows in two places for the worktree on screen: its tab's turning ring and the light in the branch row's words. Each says it in its own way, rather than two rings a few points apart saying it twice.
- Nothing in history says that the uncommitted files are still being made. The branch row says it, a column's width away.
- At the default width the line gets about 240 points, so a long line is cut. The tooltip and the popover have all of it.
- A finished reply stays in the row until the agent's next turn, which can be hours later. If that turns out to be stale, the reply could go once the worktree has been on screen for a while.
- The sidebar, the tab and the worktree menu don't change.
- The popover can't take you to the agent. Bringing forward the terminal an agent runs in would need Roga to find the app from the agent's process, and it couldn't pick the tab. A short history of the agent's last lines would need `AgentMonitor` to keep them.

## Alternatives considered

- **A2, a pill in the middle of the branch row,** as Xcode's toolbar shows its activity. It reads more clearly as a button and stands apart from the branch, but it moves whenever either end of the row changes width, as when the counts come and go, and it fights Roga's own words for the middle.
- **B, a strip under the branch row for each session.** It has the most room, with the agent's name, its whole line and buttons for every session, but each strip pushes history down 30 points, so the rows you're reading and the one you selected move whenever an agent starts or quits. Decision 48 noted the same jump in the sidebar.
- **C, the line on history's row for uncommitted changes.** It sits next to the files the agent makes and has about 400 points, but the row is only there while there are files, so it would have to come back for an agent that's only reading, and its line is out of view while history is scrolled or the panels are maximized, which is when you read the agent's diff. A click on the row already selects the uncommitted changes, so the popover would have nowhere to hang from.
- **A+C, the agent's mark in place of that row's dot.** It ties the graph to the agent, but a working agent would turn in three marks a few points apart.
- **A+S, the light through the words of history's row for uncommitted changes, with the line's ring kept.** It shipped this way in 0.0.9. It tied the files to the agent, but a working agent then showed in three places, two of them rings a few points apart that said the same thing.
