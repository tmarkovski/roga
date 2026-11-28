# 126. Give the branch row's buttons a header's size

Accepted on 2026-11-28. This changes how big the buttons at the right end of the branch row are, which [decision 120](0120-say-how-far-the-branch-is-from-main-and-make-its-menu-a-popover.md) set at 36 points along with everything else in the row. The counts, Fetch, New Branch and the order go back to 32 points, the size of the icon buttons in a panel's header. The branch, the agent's line and a worktree stuck partway stay at 36.

## Context

Decision 120 gave the branch and the agent's line two lines each, which need 36 points. It made every other control in the row 36 points too, because the counts then sat right after the branch, between the two-line blocks. At 32 they would have been 4 points shorter than their neighbours, and the gray under the pointer would have changed height as it slid along the row.

Two things have changed since then:

- [Decision 124](0124-put-pull-and-push-beside-fetch.md) moved the counts to the right end of the row, beside Fetch. No button sits between the two-line blocks any more. The buttons at the right end now sit only beside each other and the line before the order.
- The branch and the agent's line now fade in a row's lighter gray under the pointer, rather than a button's, because a click on either only opens a popover that shows more. They no longer look like the buttons beside them, so there's no reason for the two to share a height.

At 36, the buttons were the only icon buttons in the window bigger than a panel header's, though the branch row is 44 points tall and lines up with the refs panel's header, whose buttons are 32.

## Decision

**The counts, Fetch, New Branch and the order are 32 points,** as big as the icon buttons in a panel's header, with the same corners and the same gray under the pointer. They sit in the middle of the row's 44 points, with 6 above and below. The space between them, and the line before the order, are as they were.

**The branch, the agent's line and a worktree stuck partway stay 36 points tall,** as their two lines need. A worktree stuck partway sits right beside the branch, which is the case decision 120 was about, so it keeps the branch's height.

## Consequences

- The branch row's buttons match the refs panel's header beside it, and the other panels' headers.
- The row has two heights: 36 for the parts that say something and open a popover, and 32 for the buttons. The lighter gray of the first already sets them apart.
- The buttons take 4 points less room each, so a narrow column leaves a little more to the agent's words.
- The order's button keeps a size of its own in `HistoryCommands`, which the branch row passes in, so it can't drift from the others.

## Alternatives considered

- **Keep every control at 36.** It keeps the gray the same height from one end of the row to the other, but that mattered only while a button sat between the two-line blocks, and it leaves the row's buttons bigger than every other header's.
- **Make the two-line blocks 32 too.** Their text would have about 2 points above and below, which decision 120 already turned down.
