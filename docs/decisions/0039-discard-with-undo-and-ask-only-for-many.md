# 39. Discard changes, with Undo, and ask only for more than one file

Accepted on 2026-11-05. This builds on [decision 30](0030-stage-and-commit-beside-history.md), which said discarding would come next, and on [decision 29](0029-dialogs-that-say-what-happens-and-show-the-command.md) for its dialog.

## Context

Staging had a way out and discarding didn't, so throwing away part of an agent's work meant going to the command line. It has to work at four sizes: a hunk, a file, a folder, and everything uncommitted.

The design canvas's Commit page had every discard ask first, through a dialog. Asking every time is the thing people turn off, and [the vision](../../VISION.md) wants no confirmation dialogs for routine operations, and going through an agent's change hunk by hunk is routine. But decision 29 says Roga asks when something can't be brought back, and unstaged lines can't: they were never in git. Doing without a dialog needed something else to catch a slip.

git has no undo for this. `git restore`, `git apply --reverse` and `git reset --hard` overwrite files, and the reflog only knows about commits.

## Decision

**One file or less doesn't ask, and more than one does.** A hunk and a file take one click. A folder or a heading with one file in it does too, because it's the same thing. A folder or a heading with more opens the dialog. Discarding everything always asks.

**Undo is what makes that safe.** Roga keeps what's about to go, just before it goes. The title row says `Discarded LoginView.swift` with an Undo button for 8 seconds, as it does for a commit, and Changes > Undo Discard stays, going back through the last 20 one at a time.

| Discarding | What's kept | What Undo does | How long it lasts |
| --- | --- | --- | --- |
| A hunk | Its patch, in memory | `git apply` | Until Roga quits |
| A file | Its patch from `git diff-files --binary`, in memory | `git apply` | Until Roga quits |
| An untracked file | The file itself, in the Trash | Moves it back | Until the Trash is emptied |
| Everything | A commit from `git stash create`, which no ref points to, and the Trash | `git stash apply --index`, and moves the files back | Until Roga quits, though git keeps the commit until it prunes it |

`git apply` is all or nothing, so if something has changed the lines where a hunk would go, Undo says what git said and changes nothing. That discard stays ready to try again, because its patch is the only copy. A patch over 64 MiB isn't kept, so that discard says what it did with no Undo. Together, patches can hold 128 MiB, and the oldest go first. This is for slips rather than a history, so none of it is written to disk.

**What goes where.** Each button acts on what's around it, the way staging does.

| What | Where | What runs |
| --- | --- | --- |
| A hunk | A button on its band while the pointer is anywhere in that hunk, and on right-click | `git apply --reverse` |
| An unstaged file | A second button on the row, in red, before the one for staging | `git restore --worktree` |
| An untracked file | The same place, with a trash can | Moves it to the Trash |
| A folder | The same button on the folder's row | The above, for its files |
| A heading | `Discard All…` beside `Stage All`, or `Discard 3 Matching…` with a filter | The above, for its files |
| Everything | The panel's header, Changes > Discard All Changes…, and right-clicking history's row | `git stash create`, then `git reset --hard`, and untracked files go to the Trash |

The button comes before the one for staging so that staging doesn't move. As the panel narrows, a heading's line counts go first, then `Discard All…` becomes just its icon, and then `Stage All` does too, because a button cut short says nothing. The heading's title and count never give way, since they say which files the buttons act on. A minimum width for the panel wouldn't do instead: with a filter, `Discard 12 Matching…` and `Stage 12 Matching` need about 380 points, more than the panel's default of 320. The buttons are only there while the pointer is, so VoiceOver gets them as actions on the heading. A hunk's button shows only while the pointer is in that hunk rather than on every band as the canvas drew it, so that nothing red sits beside every hunk while someone is only reading, and it's the same rule as a row's. It stays at the edge of the view as the text scrolls sideways.

| Command | Shortcut |
| --- | --- |
| Discard File | Option-Command-Delete |
| Discard All Changes… | Shift-Option-Command-Delete |
| Undo Discard | Shift-Option-Command-Z |

**Untracked files go to the Trash rather than through `git clean`.** git has no copy of them, so the Trash is the only way to get one back, and it outlasts Roga. Moving to the Trash is ink rather than red in a dialog, because red is for what can't be brought back. Folders left empty go too, using `rmdir`, which can't remove one with anything in it, such as an ignored file.

**Staged files have no discard.** It would have to destroy any unstaged edits in the same file too. Leaving it out means staging is how someone keeps a version: discarding an unstaged file goes back to what's staged. Only Discard All Changes reaches staged files.

**What Roga leaves alone,** each because of something that was tried against real git:

- A repository inside the worktree, such as an agent's worktree, shows up as one untracked row ending with a slash, and moving it would take its whole `.git`. It gets no button, and Discard All Changes leaves it and says so.
- `git restore` empties a file added with `git add -N` and exits with 0, because the index has that file with no contents. So it goes to the Trash like an untracked file.
- `git reset --hard` silently ends a merge in progress, so Discard All Changes waits while a worktree is stuck partway, as it does while anything else is running.
- git refuses to restore a conflicted file, and resolving conflicts is its own feature, so those rows have no button.
- `git restore` does nothing to a modified submodule, so that row has none either.

**A hunk's patch is rewritten rather than cut out as it was.**

- Its header says where its lines are in the file as it is now, on both sides. Applying in reverse, git starts looking at the old side's number and takes the first place that matches. That number is off by whatever the hunks above have added, so with git's own numbers, discarding a hunk could take out a different hunk that made the same change, and a test does exactly that. Forward, git starts from the new side's number, so one patch works in both directions.
- Lines about the file's mode are left out, or discarding a hunk of a file that was also made executable would undo that too.
- It isn't offered for a file that's new, gone or changed kind, where there's no hunk apart from the file, or for staged diffs.

**A double-click doesn't take two.** After a discard, the next row or hunk moves up under the pointer, so the second click of a double-click is ignored on these buttons. The same hunk can't go twice either, while its button is still showing and the new patch hasn't been read.

## Consequences

- Hunk and file undos are gone once Roga quits. They could be written to disk, at the cost of cleaning them up, if someone loses work this way. Until then, a stash commit from Discard All Changes can still be found with `git fsck --lost-found`, and a discard that couldn't be undone still leaves nothing else changed.
- Discard File uses `git restore`, which takes what's on disk at that moment, including lines an agent wrote after the diff on screen was read. Undo brings those back too, because the patch is read just before they go. A hunk doesn't have this problem, because only the lines on screen go, and git refuses if they've changed. This is another reason to build live refresh, as decision 30 says about staging.
- A hunk has no keyboard command yet, because the diff has no idea of a current hunk. Moving between hunks would bring both, and Stage Hunk can use the same band.
- Before the first commit there's nothing for `git stash create` to compare with, so staged files can't come back from Discard All Changes. Untracked ones still can.
- A row's accessibility label names its discard, but a hunk's button only exists under the pointer, so VoiceOver can't reach it.
- A file whose button moved it to the Trash can't come back if something has been written in its place, or if the Trash has been emptied. Undo says so.
