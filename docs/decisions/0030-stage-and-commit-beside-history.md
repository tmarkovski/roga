# 30. Stage and commit in the panels under history

Accepted on 2026-11-04. This builds on [decision 15](0015-uncommitted-changes-as-a-row-in-history.md) and settles the option of showing changes as a view of their own, which [the main window](../main-window.md#options-were-keeping-open) kept open until staging arrived.

## Context

Decision 15 put uncommitted changes in a row at the top of history, with a panel for their files under it. Staging and committing need room that panel doesn't have. At the default 340 points, a diff shows about 15 lines, which is about one hunk, and a message box under the list leaves room for a few rows, so the staged files fall out of view just when they matter most. Hunk staging decides the layout, even though it's built second.

We drew six layouts at 1440 by 860 on the design canvas's Commit page: the panel as it is with a message box added, history giving way, the message as the first row of history, a commit column in place of the refs panel, and history giving way with every file in one scrolling diff. Writing the message in history's first row read best on the graph, but it put the message at the top of the window and the files at the bottom, and a row has no view to hold a text box. A commit column took the refs panel away whenever the row was selected, which fights with the panel's own button, and left the diff short.

## Decision

**The split remembers a second height.** While the row for uncommitted changes is selected, the split between history and the panels has a height of its own. Until someone drags it, it leaves history its first row and four commits, which is enough to watch a commit land. In a window 860 points tall, the diff gets about 33 lines. There's no view to switch to, so decision 15 stands.

**Two lists, and the index is git's.** Files stay under the headings Conflicts, Unstaged, Untracked and Staged, and staging moves them, using the index itself. Checkboxes would have been state of yaga's own, which [the vision](../../VISION.md) rules out. Staged files sit in a list of their own right above the message, so they stay in view however long the others get. They take up to 45% of the room before they scroll.

**Staging is one motion with reading.**

- A row's button shows while the pointer is over it, in place of its line counts, so nothing moves. Double-clicking the row does the same. A conflict's button says Mark Resolved, because that's what staging it means.
- A heading offers Stage All or Unstage All while the pointer is over it. It acts only on that heading, so an agent's stray notes under Untracked don't come along with Unstaged, and with a filter it acts only on what the filter leaves, as `Stage 3 Matching`.
- A folder's row in a tree has the same button.
- Space and Command-S stage or unstage the selected file, and the selection moves to what took its place, so going through a list is one key per file. The diff panel's header has the same button, for when the pointer is already there.
- A row moves straight away, and git catches up behind it, because on a large repository waiting for `git add` and a new list after each press would feel slow. Presses in a row go to one `git add`, and a new list follows and corrects the counts. If git refuses, the sheet says so and the new list shows how things really are.
- Every path goes through `--pathspec-from-file` with `GIT_LITERAL_PATHSPECS`, so that a file called `*.txt` is only that file and a long list fits. Another git holding the index lock, such as an agent's, gets about 4 seconds to let go.
- Unstaging uses `git reset`, because `git restore --staged` needs a `HEAD`, and it takes a moved file's old path along, or that would stay staged as deleted.

**One text box for the message.** The first line is bold, the way the commit panel will show it, and a pasted message just works. The first Return leaves the blank line git expects after a subject. A count after the first line turns red past 72 characters, and nothing stops you. Automatic quotes and dashes are off, because other tools read a commit's message. What's being written is kept for each worktree, so switching between agents or quitting doesn't lose it. It's someone's typing rather than the repository's state, so it lives in yaga's settings.

**The button says what it will do.** It reads `Commit 2 Files`, or with nothing staged `Stage All and Commit`, which takes everything listed right above it. It's orange when a click would run, as in decision 19. Command-Return does the same, and Shift-Command-Return also pushes, the way `↑` does.

**Commits go through the user's git.** `git commit -F -` runs their hooks and signing as at the command line, and leaves lines starting with `#` alone. The title row says **Committing…** with no house, like a fetch, because nothing moves between here and a remote.

- A commit that takes more than a moment says it's waiting for hooks or signing, with a button that stops git.
- A failure shows in the box with what git printed, rather than in a dialog, because a hook failing is routine. The message stays, and the button says Try Again. Skip Hooks runs `--no-verify`, except after signing failed, which it wouldn't help.

**What happens next.** With files left, the row stays selected and the box empties, ready for the next commit, which is how to split an agent's change into several. With none left, the row goes and the new commit is selected, and the split goes back to its usual height. Either way the title row says `Committed 9f2c1ab` with an Undo button for 8 seconds, and Changes > Undo Commit stays until the next one.

**Undo Commit.** `git reset --soft` back to the commit `HEAD` was on, which leaves the files staged, and the message goes back in the box. It refuses if anything has moved `HEAD` since, because that would lose an agent's commit. A first commit has nothing to go back to, so it isn't offered.

**Amending, merges and rebases.** Amend fills the box with `HEAD`'s message, and unticking it brings back what was there. If `HEAD` is already on the upstream, a sentence says pushing will need a force push. During a merge, the box starts with `MERGE_MSG` without its comments, the button waits with `2 Conflicts Left` and then says Commit Merge. During a rebase, it shows the message of the commit that stopped, and the button says Continue Rebase.

**The keyboard.** They're in a new Changes menu.

| Command | Shortcut |
| --- | --- |
| Go to Uncommitted Changes | Shift-Command-U |
| Stage File or Unstage File | Command-S, or Space in the list |
| Stage All | Option-Command-S |
| Unstage All | Shift-Option-Command-S |
| Write Commit Message | Command-L |
| Commit | Command-Return |
| Commit and Push | Shift-Command-Return |
| Amend | Option-Command-Return |
| Undo Commit | Option-Command-Z |

## Consequences

- Arrowing from the row to the commit below it moves the split. Dragging the split so that the two heights match stops that.
- Stage File runs `git add`, which takes what's on disk at that moment, including lines an agent wrote after the diff on screen was read. The Staged list shows the result, and the new list after each change keeps it honest, but this is the strongest reason to build live refresh soon. It's in the roadmap's release 1 and isn't built yet.
- A rebase's message can't be changed from the box yet, because `git rebase --continue` takes it from a file of git's. It says so by being gray.
- With no uncommitted files there's no row, so a clean worktree has no way to reword its last commit yet.
- `commit.template` isn't read yet. A template's comment lines would need `--cleanup=strip`, which would also take lines someone wrote on purpose, such as `#123 was about this`.
- Hunks, lines, discarding and selecting several files were drawn on the canvas, and they come next. Discarding will use [the sheet](0029-dialogs-that-say-what-happens-and-show-the-command.md).
- Each worktree with a draft keeps a setting, which stays behind if its worktree is deleted with something still written.
- A second scrolling diff, one file after another, can still replace the diff panel's side of this layout. It's what branch review wants too, and it needs its own prototype, because decision 9's text view shows one file at a time.
