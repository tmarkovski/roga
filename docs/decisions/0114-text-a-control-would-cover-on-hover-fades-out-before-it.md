# 114. Text that a control would cover on hover fades out before it

Accepted on 2026-11-26. This takes the fade that [decision 51](0051-marks-at-the-right-of-a-sidebar-row-and-names-that-fade.md) gives a name that doesn't fit, and uses it for whatever a control would cover while the pointer is over a row. The rows of [decision 30](0030-stage-and-commit-beside-history.md) still show their button in the place of their line counts.

## Context

A row in a worktree's list of files shows its buttons at its end while the pointer is over it, in the place of its line counts, so that nothing moves. That works while the buttons fit in that place. A conflicted file's button says Mark Resolved in words, which is much wider than any count, and a file without counts, such as an untracked one, has no place at all for its two icons. Their gray fill then drew over the end of the file's name and folder.

Making room for the buttons stopped the overlap, but then the name was cut short in the middle again each time the pointer came onto the row, so its words changed under the pointer, from `ResolvedAlreadyB…AsConflicted.swift` to `ResolvedAlready…sConflicted.swift`, and changed back when it left.

## Decision

**While a control shows over the end of a row, the row's text stays where it is, and whatever of it would reach the control fades out before it.** The text is whole up to 26 points before the control and fades out over the next 18, so that it's gone 8 points before the control's edge, which are the fade and the gap that decision 51 gives a name in the sidebar. Text that ends sooner is untouched, so a row whose buttons fit in the place of its counts looks the same with the pointer over it as without. Nothing is laid out again, so nothing on the row moves or changes its words when the pointer comes or goes.

This holds wherever a control comes over text on hover:

- In a worktree's lists of files, a file's row and a folder's row fade their name and folder before their buttons: Stage, Unstage, Discard, Move to Trash, Update and Mark Resolved.
- In the refs panel, a row's commands take the place of what's at its right, and its name and the line under it give way to them. The name already faded (decision 51). The line under it, such as how far a branch is ahead and behind or a tag's subject, was cut short with an ellipsis, and now fades as well, with the pointer over the row or not.
- The sidebar's rows and the worktrees' tabs already keep a place for the button they show on hover ([decision 58](0058-the-mark-under-the-menus-button-and-the-count-before-it.md) and [decision 95](0095-a-repositorys-worktrees-as-tabs.md)), so it covers a mark or a count there, never text.

A control that's added to a row later follows the same rule: either the row keeps a place for it, or the text fades out before it.

**Text that doesn't fit with nothing over it is cut as it was.** A file's name and folder are still cut in the middle when the row is too narrow for them, because the end of a file's name, with its extension, is often what tells two files apart. The fade is for what a control covers, not for fitting a row.

## Consequences

- A button that comes over a row never has text under its fill or its words.
- A file's name that's already cut in the middle can also fade at its end while the pointer is over its row, as in `UntrackedNotesWithAnEv…erNameThanTheOthers.m` fading out before the trash icon. Its tooltip still has the whole path.
- The rows of a commit's files have no buttons, so they look as they did.
- In a file's row, the fade is a mask over the row's text, shaped by a hidden copy of the buttons' labels, so it ends where the buttons begin whether they're icons or words. It's only there while the buttons show.
- Text that ends within the 18 points of the fade is dimmed a little at its end while the pointer is over the row, even though it doesn't reach the control. A name that's long enough to reach it fades out fully.
- A long line under a ref's name now fades out at its end rather than ending in an ellipsis, as the sidebar's second line does.
