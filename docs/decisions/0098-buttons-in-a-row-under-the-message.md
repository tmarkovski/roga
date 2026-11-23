# 98. The message box's buttons in a row under its text

Accepted on 2026-11-23. This changes how [decision 30](0030-stage-and-commit-beside-history.md)'s message box is laid out: its heading, its Amend checkbox and its footer give way to one row of buttons under the text. It moves [decision 41](0041-agents-status-from-their-hooks-and-messages-from-their-clis.md)'s Generate button and the line under the box into that row, makes the box shorter than [decision 55](0055-split-the-panel-for-uncommitted-changes-40-40-and-20.md)'s 146 points, and runs [decision 68](0068-mark-an-agents-commands-with-an-orange-line-rather-than-sparkles.md)'s light along the line over the box rather than around a border.

## Context

The box was three bands stacked under the files. A heading said where the commit goes and held Amend, the text box held Generate in its bottom right corner, and a footer held ⌘↩ and Commit. At the default width of 320 points an empty box took 146 points, and its text got 29 of them, because the text box kept 27 points under the text free for Generate. Generate and Commit sat at the right edge 30 points apart, so they read as a pair even though one writes the message and the other commits it. The agent's note and the hooks' line went between the text and Commit, so Commit moved down whenever one of them showed.

Chat apps put their buttons on a row under the text: tools at the left and the button that sends at the right. We drew three ways to do that on the Commit box page of the design canvas, at 320 points with the files above them, and the generator is in [`docs/design/commit-box`](../design/commit-box). A kept the heading and moved Amend into the row as a toggle. B put Generate at the left and Commit at the right, with Amend behind Commit's chevron. C used a round button that sends, with its words beside it in gray.

## Decision

**One row of buttons under the text: Generate at the left, and Commit at the right.** The heading and the footer go. Generate says Rewrite once the box has words, as it did, and Undo sits beside it after an agent writes, with the sidebar's dot for what finished. Who wrote the message and how fast, which the line under the box said, is in Undo's tooltip and VoiceOver hint.

**Commit's chevron has the Changes menu's own group, with the same keys:** Commit, Commit and push, and Amend, in the sentence case of a menu in the window. The chevron stays while Commit can't be pressed, since Amend is how an empty box gets a message to change, and it goes while a merge, a revert, a cherry-pick or a rebase is partway, when neither Commit and Push nor Amend can run. The ⌘↩ hint moves into Commit's tooltip and the menu.

**A chip at the top of the box says what kind of commit it is, only when it isn't an ordinary one to the current branch:** Amending with the commit, Merging, Reverting, Cherry-picking, Rebasing with the branch, First commit on with the branch, and Detached HEAD. The branch row under the tabs ([decision 95](0095-a-repositorys-worktrees-as-tabs.md)) already names the branch, so an ordinary commit shows nothing. Amending's chip is filled with ink, the way what's chosen is, and its ✕ puts the draft back. The sentence about a force push or a detached `HEAD` goes under the chip.

**Whatever's running shows where it was started, with Stop in that button's place.** While an agent writes, Generate turns into Stop, with the sidebar's ring, the agent's line lit around it, and the seconds beside it. While hooks or signing take a while, Commit turns into Stop with a spinner, and the words that say what it's waiting for go where Generate was.

**Failures and warnings go at the top of the box, each with its own way on.** A commit that didn't go through shows what git or the hook printed, with Skip Hooks under it when a hook could have been why. An agent that couldn't write shows why, with Try Again and Agent Settings…. Staged changes that changed while the agent wrote say so. Each failure has a faint red fill rather than an outline, inside the box. So the row of buttons never moves.

**The box has no border of its own.** The canvas drew it as a rounded card, the way a chat app floats its box over a conversation, but here the line over the box and the panel's sides and bottom already close it in, so the card was a box inside a box. Without it the text lines up with the files' names above it, the buttons are 8 points from the panel's sides and bottom, and the light that says an agent is writing (decision 68) runs along the line over the box. That light keeps the window's own appearance, where the one along a dialog's command block is always dark, so it's a shape of its own, `topLine`.

**The row's words get shorter, a step at a time, when it's short of room:** Generate leaves out the agent's name, then Undo becomes an arrow, then Commit leaves out its count, as in `Commit` for `Commit 2 Files`, and in the narrowest panels Commit goes onto a line of its own. The box measures the words in the system font against the width the panel gives it. Generate and Commit are both 12 points and 26 tall, with a point less padding than Generate had, so at 320 points Generate with Claude fits beside Commit 2 Files.

## Consequences

- An empty box is 100 points at the default width, 46 fewer than before, and its text gets three lines rather than 29 points. It stays shorter whatever it shows, since nothing goes between the text and Commit any more.
- Amend takes two clicks or ⌥⌘↩ rather than one, and its state shows in the chip and in Commit's words rather than in a checkbox.
- An ordinary commit no longer names its branch in the box.
- The agent that wrote a message, and its model, show only in Undo's tooltip.
- Commit's chevron menu has the same keyboard shortcuts as the Changes menu, as the branch chip's menu has the branch menu's.
- `CommitComposer.heading` is gone. `chip` says what the chip shows, or nil, and `Action.shortTitle` and `Action.menuTitle` give Commit's words for a short row and for its menu.
- At 320 points, Generate with Claude fits beside Commit for up to a few hundred staged files. A longer count, or Stage All and Commit, makes it Generate.

## Alternatives considered

- **A, Amend as a toggle in the row, with the heading kept.** Amend stays one click, but three buttons don't fit on one row at 320 points with their full words, and keeping the heading saves only 4 points over the old box.
- **C, a round button that sends.** It's the most like a chat app, but Commit's words say what a click will do, such as Stage All and Commit, 2 Conflicts Left and Continue Rebase, and as gray words beside an icon they read as a caption. The arrow chat apps use means push in the branch row, too.
- **B in a rounded card, as the canvas drew it.** It looks most like a chat app's box, and costs 11 points of height and 16 of width for an edge the panel already has.
