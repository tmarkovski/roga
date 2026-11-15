# 83. Open a new ref's popover where it was asked for

Accepted on 2026-11-15. This finishes what [decision 82](0082-make-worktrees-from-the-sidebar-where-theyre-listed.md) started for worktrees, and changes [decision 45](0045-fetch-and-new-branch-as-buttons-and-the-commit-count-with-history.md) again, which hung every popover for a new branch or tag from the New Branch button.

## Context

After decision 82, three commands still opened a popover across the window from where they were asked for:

- **Create › Branch here…, Worktree here… and Tag here…** in history's menu, which starts from the commit you right-clicked.
- **The same Create** in the menu of a branch or tag in the refs panel ([decision 65](0065-one-menu-for-a-commit-or-a-branch.md)).
- **New branch from stash…** in a stash's menu in the refs panel ([decision 81](0081-stash-in-one-click-and-put-stashes-back-from-their-menu.md)).

Each opened under the New Branch button at the top right of the window, so the eye had to leave the row it had just picked and find the popover somewhere else. The popover's title said which commit it starts from, but nothing on screen tied it to the row.

## Decision

**A popover asked for from a row's menu hangs from that row.**

- **In history** it opens under the row, where the pointer was when the menu opened, so it's under the commit or badge that was right-clicked.
- **In the refs panel** it opens at the row's left edge, facing the middle of the window.

**Everything else stays where it was.** The New Branch button, the branch's menu, Shift-Command-B and the menu bar still open New Branch under the button, which looks pressed only then. A command run from VoiceOver's list of a row's actions, where no menu opens, uses the button too.

The popovers themselves don't change: the same fields, the exact command, git's refusal and Return.

## Consequences

- A row's menu says where it opened, and its commands use that place for a second after the menu closes, which is when they run. A command that comes later, or from somewhere else, finds no place and opens at the button.
- History's rows are an AppKit table, and SwiftUI's popover can only hang from the view it's attached to, so these popovers are AppKit popovers showing the same SwiftUI content. They close for a click elsewhere or Escape, and once their branch or tag is made, as before.
- If history loads again while one is open, as when an agent commits, the popover stays where it opened, even if the row has moved.
- History's order menu now uses the refs panel's sort icon rather than the filter icon. It orders history and leaves nothing out, and the filter icon would have clashed with a filter for which branches history includes.
