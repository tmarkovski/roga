# 31. Chevrons for what folds, and lines down a tree of files

Accepted on 2026-11-04.

## Context

[Decision 24](0024-icons-as-custom-symbols-from-lucide.md) kept a small triangle for anything that folds, drawn with Lucide's Play icon, and gave chevrons to controls that open a menu. In practice the chevron on the branch's chip looks better than the hollow triangle, and it's the mark most people expect beside something that folds.

In a tree of files, indenting was all that tied a row to the folder above it, which gets hard to follow in a deep tree or a long folder.

## Decision

**What folds has a chevron.** It's the chevron from the branch's chip, at the same size, weight and gray, in all four places that had the triangle: a repository's worktrees in the sidebar, a section of the refs panel, a commit's message, and a folder in a tree of files. It points right while closed and down while open, and it still turns a quarter of the way around between them.

**A chevron no longer says which of the two it does.** This replaces decision 24's rule that a triangle means something folds and a chevron means a menu opens. An open section's chevron now looks the same as a chip's, and what's around each one tells them apart. `Icon.disclosure` and `Icon.dropdown` stay as two names, so either can change without the other.

**An open folder has a line.** A thin line runs from under the folder's chevron, past everything in the folder, and stops where the folder ends. It's one point wide, in `primary` at 14%, so it's quieter than the line under a repository's worktrees, because a deep tree can have several side by side.

**Each row draws its own lines.** A row draws one line for each folder it's under, working that out from its depth alone. Rows have no gap between them, so the pieces join up. Nothing changes in the rows' model, the rows stay one height for the lazy stack, and rows that aren't on screen draw nothing, however large the merge.

## Consequences

- A filter's rows and a list's rows have a depth of 0, so they have no lines.
- A line sits half a point to the right of the middle of the chevron above it, because it's on a half point to stay sharp on a display that isn't Retina, as the sidebar's line is.
- The lines are under a row's fill and made of a translucent color, so they still show on a selected row and a hovered one.
- The sidebar's line stays as [decision 17](0017-a-line-and-a-row-for-a-repositorys-worktrees.md) has it, with its corner into the last row.
