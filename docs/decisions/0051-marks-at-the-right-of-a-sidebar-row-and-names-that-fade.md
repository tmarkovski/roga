# 51. Marks at the right of a sidebar row, and names that fade

Accepted on 2026-11-06. Partly supersedes [decision 48](0048-a-second-line-under-a-sidebar-row-while-theres-something-to-say.md), which starts a row's second line with the agent's mark, makes the row 48 points tall and runs the line's words and how long together, and the part of [decision 41](0041-agents-status-from-their-hooks-and-messages-from-their-clis.md) where a worktree's row shows a button for a new window on hover. Long names in the sidebar and the refs panel now fade out at their end, rather than being cut short with an ellipsis in the middle.

## Context

Decision 48 was built and merged the same day. Looking at it again in the design canvas's clickable board, we found the marks work better at the right than at the start of the second line. There, the mark sits beside the row's menu button and as wide as it, and how long sits at the right of the second line, under the mark and the button, with the words running toward it and fading out before they reach it. Without a mark at its start, every second line also starts in the same place.

The same applies to names. A branch cut in the middle, as in `agent/docs-re…ding-guide`, is hard to read, and the sidebar and the refs panel were doing it to branches, repositories and their details.

## Decision

**An agent's mark sits at the right of the row's first line,** in a box 24 points wide, the width of a command's button, right before the count. It's there whatever the second line says, and stays while the pointer is over the row. The count's place is at least 24 points wide while there's a mark, and keeps the width of the wider of the count and the commands, so the mark doesn't move when the count gives way to the menu's button on hover, or when the count goes. The count and the button stay at the right edge on every row, whether or not it has an agent, and the marks line up in a column just before them.

We put the mark before the count rather than after it. After it, the count and the menu's button would move 24 points to the left on a row with an agent, and the button wouldn't be in the same place from one row to the next.

**A worktree's row shows only its menu's button on hover.** Open in New Window and Open in Terminal are in that menu, and in the context menu.

**The second line comes in two parts.** Its words start under the row's own text, as before, and run toward the right edge. What's short stays whole at the right, ending where a count does: how long an agent has been at it, as in `6 min`, or how far along stopped work is, as in `2 conflicts`. The words fade out over their last 18 points when they don't fit, at least 8 points before that end. The `·` between them goes, since they're apart now. Conflicts from something else, with nothing underway to name, have only `1 conflict`, from the line's start.

**The second line starts 28 points down, and a row with one is 52 points tall,** so there's a little more room between the two lines. The first line stays where it is in a 32-point row.

**Names fade out at their end** rather than being cut short with an ellipsis: in the sidebar, a repository's name, the branch or folder after it, a worktree's branch and the row for hidden worktrees, and in the refs panel, the names of branches, remote branches, tags, folders and remotes, and a stash's message. A name that fits is drawn as it is. One that doesn't shows its start, faded over its last 18 points, and its tooltip has all of it. A remote's address in the refs panel is still cut in the middle, because it's an address rather than a name, and its middle is what matters least.

## Consequences

- The marks no longer start a second line, so the words on every second line start in the same place, under the row's own text.
- At the sidebar's default width, `Needs your OK: git push` and `2 min` now fit whole in a worktree's row, which decision 48 cut to `git…`.
- A row with an agent gives the branch's name 24 points less than one without. A count with the triangle for conflicts, or with three digits, is wider than 24 points, so its row's mark sits that much further left.
- Two branches that differ only at their end, such as `release/2.3.1` and `release/2.3.2` in a narrow refs panel, look alike until the panel is wider or the pointer rests on one, where cutting in the middle would have shown both ends.
- A row is 4 points taller while it has a second line, so a list with many agents at work shows a little less.
- The design canvas's Second line boards still draw decision 48. The code is the reference for this.
