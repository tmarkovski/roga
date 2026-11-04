# 29. Dialogs that say what happens and show the command

Accepted on 2026-11-04.

## Context

Everything yaga asked or reported went through native alerts. [VISION.md](../../VISION.md) wants the user to always be able to see the command an action corresponds to, and native alerts got in the way of that. Measured with a real `NSAlert`, macOS gives one a column 260 points wide, and its text can't be styled. Deleting a branch and aborting a rebase showed their commands as ordinary words at the end of the message, where they didn't look like commands, and a long one wrapped. A force push didn't show its command at all. SwiftUI's alert can't hold anything custom, so none of this could be fixed from inside one.

Choosing between rebasing and merging, when a branch had diverged and `pull.rebase` wasn't set, was two items in a menu. That's quick, but it has no room to say what either does, and nothing to stop it being asked again next time.

We drew the options on a design canvas, in the style of a dialog in the Claude app: a left-aligned title, an ×, gray inset cards, gray helper text and an ink button.

Where the command goes:

- **In a block above the buttons.** You read what happens, then what exactly runs, then reach the button. It's the most conventional, and the closest to the dialog it was drawn from.
- **Along the bottom edge, with the buttons above it.** This looks the most like a terminal, and it's the one we chose. The buttons sit on top of the block, so they're higher on a dialog with more to show.
- **In a dark footer that also holds the buttons.** This has the most character, but it's heavy for a dialog with one line to say, and in dark mode it's hardly different from the last one.

How to choose between rebasing and merging:

- **Rows with a sentence each, then a button.** It's plain, and it reads like the menu it replaces.
- **Pictures of the graph that each leaves behind.** Only yaga could do this, because it's what yaga draws all day. This is the one we chose.
- **A switch.** It's the most compact, but it stops working past three options.
- **A popover from the count that was clicked, where clicking a row runs it.** It's the lightest, and it's today's menu with a sentence added.

## Decision

**A dialog is one shape.** It has a title and an ×, what will happen, any gray cards listing what's at stake, a small gray note, the buttons, and then the terminal block along its bottom edge. `DialogContent` says what a dialog says, and `DialogSheet` draws it, so wording can be tested without a window.

**It's a real sheet, not an overlay.** An overlay would draw exactly what was sketched, with a dimmed window behind it, but history's table, the menu bar and VoiceOver would all carry on underneath it. A sheet blocks the window and handles focus for free.

**The block shows exact commands, in Monokai's colors, dark in both appearances.** An option that can lose something, such as `-D` or `--force-with-lease`, is in pink, so that the part worth reading stands out. Arguments are quoted when a shell would split them, because Copy makes the text something people can paste. It stops growing at 220 points and scrolls, because a hook can say a lot.

**Copy gives what will run.** With commands still to run, it copies only those, ready to paste. After something has run, it copies what happened, as it reads in the block. So the dialog for a pull that stopped on a conflict copies the undo command rather than the pull that already ran.

**A failure shows what ran and what git said.** The command comes from the error itself, so it's what really ran, including the likes of `--end-of-options`. A failure with nothing from git to show, such as a folder that isn't a repository, has only words, and no block.

**Red is only for what can't be brought back.** A destructive button is red, and Return doesn't press it, so it takes a click or Command-Return. Other primary buttons are ink, and Return presses them. Escape and the × are always Cancel. So **Undo the pull** is ink, because it's the way out.

**Words are in sentence case**, as they are in the dialog this was drawn from, rather than the title case of native alerts. Menus keep title case, because they're still native.

**None of this adds questions.** Pull, push and checkout still run without asking, as the vision wants. Yaga only asks when something can't be brought back, when it reaches a remote, or when git needs a decision. Every window still shows one dialog at a time.

**Rebase or merge is a dialog, with pictures.** `↓` opens it straight away when the branch has diverged and `pull.rebase` isn't set, and the branch's menu has **Pull…** in place of the two items, which also gives it Shift-Command-L. Each option draws the graph it leaves behind, the button's label and the command follow what's picked, and the left and right arrow keys pick. Up to 4 commits on a side get a dot each. Past that, a dotted line stands for the rest and the label says how many. It shows the shape of the result rather than the actual commits, which don't exist yet.

**Remember writes to git's config rather than to yaga's.** **Remember for this repository** adds `git config pull.rebase true` or `false` to the command, and yaga then follows it like any other config ([decision 19](0019-pull-and-push-from-the-branch-in-the-title-row.md)). Nothing is hidden from the command line, and git itself pulls the same way from then on. It starts off, because it writes to the user's config.

## Consequences

- The buttons aren't at a fixed distance from the bottom edge: about 60 points above it for a force push, and about 175 for a dialog with a lot to show. Because they come before the command, you read past them and back up to click.
- Words that introduced what git said no longer work, because the buttons sit in between, so failures say "What git said is below."
- `git` writes a conflict's files to its standard output, which yaga doesn't keep when it fails, so that dialog lists them in a card from `git status` and shows only the command that ran. It could show git's own words if the output were kept.
- A sheet's corners and shadow come from macOS, and its dimming of the window behind is lighter than the sketch's.
- A sheet doesn't change size once it has opened, and what's in it just overflows. So the rebase or merge dialog keeps an empty line in the block, for the one that remembering adds. Nothing moves when the toggle flips, but a dialog whose content can grow has to leave room for it.
- A keyboard shortcut can keep a button's older action until the button's title changes, which once ran a pull without remembering it. So what's picked lives in the model, and a button reads it when it's pressed, rather than capturing it.
- The picture can look simpler than the real result, because it draws a history with merges in it as a straight run of commits. It could draw the real commits one day, using what history draws, but the result of a rebase doesn't exist yet.
- Anything with a question or a failure to show should use `DialogContent` rather than `.alert`, so that it looks the same and shows its command. Discarding changes will be the next.
