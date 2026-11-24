# 102. Buttons in title case

Accepted on 2026-11-24. This extends what [decision 66](0066-sentence-case-branch-icons-and-the-value-on-a-row.md) says about case from menus to buttons, and changes [decision 29](0029-dialogs-that-say-what-happens-and-show-the-command.md) for a dialog's buttons, whose other words stay in sentence case. [Decision 69](0069-set-roga-up-in-the-whole-window-the-first-time-it-runs.md) already kept setup's buttons in title case.

## Context

Decision 29 put a dialog's words in sentence case, rather than the title case of native alerts, and decision 66 did the same for the menus in the window, leaving the menu bar in title case. Nothing said what a button's label uses, and the code mixed the two. Most buttons were in title case, such as Try Again, Stage All, Skip Hooks, Move to Trash and Install Hooks, and so were setup's, as decision 69 says. A dialog's buttons were mostly in sentence case, such as Reset anyway, Keep changes, Push, then reset, Leave it uncommitted and Undo the pull, though Move to Trash, Add Agent and Open GitHub sat beside them in title case.

A review of setup on 2026-11-24 also noticed Restore conflicts and Restore Conflicts in the code. That pair follows decision 66: the first is in a conflicted file's ⋯ menu and the second is a button in the strip above the file.

## Decision

**A button's label is in title case**, as Apple's Human Interface Guidelines ask and as most of Roga's buttons already were. That covers every button in the window: setup's, Settings', the panels' and their headers', and the buttons along the bottom of a dialog. Short words such as a, the, to, of and with stay lowercase in the middle of a label, and names keep their own capitals, as in Fix with Claude.

**A label that reads as a sentence is shortened rather than capitalized word by word.** Leave it uncommitted becomes Leave Uncommitted, Commit the revert becomes Commit Revert, as the commit box's button already said, and Undo the pull becomes Undo Pull, as in Undo Merge and Undo Cherry-Pick. The words in a dialog that name a button use its new label, as in "Keep Changes leaves everything since 9f2c1ab staged", and so does the comment in its terminal, as in `# Undo Pull runs`.

**What isn't a button keeps its case.** Menus in the window, including the menus behind a button's chevron or ⋯, stay in sentence case (decision 66), as do VoiceOver's actions, which it reads as a menu. The rows of a choice in a dialog, such as Discard everything in the reset dialog, are a choice rather than a button, and a disclosure's label, such as Claude Code output, reads as a heading, so both keep sentence case.

## Consequences

- The same command can read Restore Conflicts on a button and Restore conflicts in a menu, as decision 66 already has New Worktree… in the menu bar and New worktree… in the window.
- Decisions 37, 44, 59 and 60 still name the dialog buttons they introduced in sentence case. The main window's notes use the new labels.
- The design canvas's boards keep the labels they were drawn with.
