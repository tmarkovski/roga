# 57. The mark under the menu's button, and the count before it

Accepted on 2026-11-07. Partly supersedes [decision 51](0051-marks-at-the-right-of-a-sidebar-row-and-names-that-fade.md), which put an agent's mark just before the count and kept it there on hover, while the count gave way to the menu's button. The rest of decision 51 still holds.

## Context

Decision 51 put the mark before the count so that the count and the menu's button stayed at the right edge on every row. Using it, two things were wrong. The count is the part of the row that grows, from one digit to three or with the triangle for conflicts, so the mark beside it moved left by as much, and the marks didn't stay in their column. And hovering a row hid its count, which is often what the pointer went there to read.

The mark is a single icon, as wide as the button, and the row's second line already says what the agent is doing, so the mark is the part that can give way on hover.

## Decision

**The mark sits at the right edge of the row,** in the 24-point place where the menu's button shows on hover. The button covers it while the pointer is over the row. A row with no commands, such as the row for hidden worktrees or a collapsed group's label, keeps its mark on hover.

**The count sits just before that place, and stays on hover,** as do the row's other labels, such as **Missing**, **Folder missing** and **Deleting…**. Every row keeps the place whether or not it has a mark, so the counts end in the same column on every row, whether or not it has an agent, and the pointer never hides one.

**How long, on the second line, still ends at the right edge,** now under the mark.

## Consequences

- The marks and the menu's buttons share one column at the right edge, and the counts line up in another just before it, however wide a count is.
- A row without a mark keeps 24 points at its right for one, so its name has that much less room than before. A row with a mark and a count narrower than 24 points has a little more, since the count no longer holds a place as wide as the button. A row with nothing at its right no longer cuts its name shorter on hover, because the button takes a place that's already there.
- While the pointer is over a row, its mark's tooltip can't be reached. The second line has the same tooltip.
- The design canvas's boards still draw decision 51's layout. The code is the reference for this.
