# 60. Resolve conflicts in the diff panel

Accepted on 2026-11-07. This changes what [decision 19](0019-pull-and-push-from-the-branch-in-the-title-row.md), [decision 29](0029-dialogs-that-say-what-happens-and-show-the-command.md) and [decision 59](0059-set-aside-changes-in-the-way-and-put-them-back.md) say about the dialog for a conflict, and what [decision 28](0028-show-a-worktree-thats-stuck-partway.md) says about **Show Conflicts**. It builds on [decision 30](0030-stage-and-commit-beside-history.md), which lists conflicts under their own heading with **Mark Resolved**.

## Context

Roga couldn't resolve conflicts. When a pull, a rebase, a revert or a stash pop stopped on one, a dialog offered **Undo** or **Leave it**, and after Leave it the only way on was an editor or the command line. Show Conflicts in the title row's menu selected the row for uncommitted changes, where a conflicted file's diff compared it with `HEAD`, so git's markers and the other side's lines showed as green additions, as if they were new code. Mark Resolved ran `git add` whether or not markers were left.

We drew four options on the design canvas, on the page "Resolving conflicts", all with the same worktree, and each for a merge, a rebase, a revert and a stash pop:

- **A, in the diff panel, conflict by conflict.** Each conflict is a block with a band and its two sides named, and buttons on the band. Nothing new opens. This is the one we chose.
- **B, a pane with both sides above the result,** the way Sublime Merge and IntelliJ draw it. It has the most room, but it's a mode that hides history, and it needs an editor for a whole file, which is a larger build than the rest together.
- **C, A with a way to hand a file to an agent.** We chose this to come after A, because reviewing what an agent chose uses A's blocks.
- **D, one side's whole version, and the file's editor for the rest.** It's right for a lockfile and wrong for most code, so its two choices went into A rather than standing alone.

The thing that made A work for every case was naming the sides. git calls them ours and theirs, but in a rebase and a stash pop ours is what's coming in, so a button that said Keep Ours would mean the opposite there.

## Decision

**A conflicted file shows its conflicts rather than a patch.** When a file under Conflicts has markers, the diff panel reads the file itself and shows each conflict as a band that says **Conflict 2 of 3**, in red, then each side under a row that names it, then the lines that follow. The side git calls ours comes first, so the order matches the markers in the file and in an editor. Ours is blue and theirs is purple, rather than green and red, because neither side is an addition or a removal, and the gutter has a bar of each side's color. The line numbers are the lines on disk, where the markers take lines too. When the repository's `merge.conflictStyle` is `diff3` or `zdiff3`, what both sides started from shows between them, in gray. A file without markers, such as a binary file or one that a side deleted, shows its patch as before.

**Each side is named by where it came from,** from the label git writes after the markers, the current branch, the refs and what the worktree is partway through:

| What stopped | First side | Second side |
| --- | --- | --- |
| `git merge origin/main` | `main` | `origin/main` |
| A pull that merges, labelled with a bare hash | `main` | `origin/main`, the ref at that commit |
| A rebase onto `origin/main` | `origin/main`, what it's going onto | `a17f9d3`, the commit being replayed |
| `git revert 86b3386` | `main` | The revert |
| `git cherry-pick a17f9d3` | `main` | `a17f9d3` |
| `git stash pop` | `main` | Your changes |

A side's row adds the commit's short hash and subject, or says that a rebase has already replayed some commits.

**The band's buttons resolve it.** Every band in view has **Keep main's**, **Keep origin/main's**, **Keep Both** and **Edit…**, at the edge of the view, so they stay put as the text scrolls sideways. They don't wait for the pointer, as a hunk's Discard does ([decision 39](0039-discard-with-undo-and-ask-only-for-many.md)), because resolving is the task while a file has conflicts, and nothing on them is red. Edit… opens a box under the button that starts with both sides, and Command-Return keeps what's written. A choice writes those lines into the file in place of the conflict, and the band then says what was kept, as **Conflict 2 of 3 · Kept main's**, with **Undo**.

**Roga writes the file itself, and only over what it read.** git has no command for resolving one conflict, so Roga keeps the file as it was first read and what's been chosen in it, and writes the file with those choices. The file is written in place, which keeps its permissions. Just before writing, Roga checks that the file still has exactly what it last wrote or read. If an editor or an agent wrote to it meanwhile, Roga writes nothing, says so, and shows the file as it is now, which becomes the new starting point. What was chosen lasts until Roga quits, as a discard's Undo does, or until the file is marked resolved.

**Marking it resolved stays a separate step.** Choosing doesn't run `git add`, so someone can look over the whole file first. Once a file has no markers left, the header's **Mark Resolved** turns orange, as a button that runs now does, and the header says **Conflicts · 1 of 3 left** until then. Mark Resolved still runs `git add`, and the commit box's **Commit Merge**, **Continue Rebase** or **Commit Revert** finishes as it does today.

**The header's menu keeps one side's whole version, or opens the file.** **Keep main's Version** and **Keep origin/main's Version** run `git checkout --ours` or `--theirs` for the file and then `git add`, for a file such as a lockfile where one side is right. **Open in Xcode**, named after the app that opens the file, is for resolving it there.

**Resolve takes Leave it's place in the dialogs.** The dialogs for a pull, a rebase or a revert that stopped on a conflict, and for changes that came back with conflicts after a pull, say "You can resolve them here, or undo the pull." **Resolve** is ink and Return presses it, and **Undo the pull** comes before it. Decision 29 made Undo the ink button because it was the way out, when there was nothing else to do but leave. Now resolving is what someone usually wants after a pull, and it loses nothing, since Undo stays a click away and the title row's menu keeps **Abort Merge…**. Escape and the × still close the dialog and leave everything as it is. A revert's Undo stays red when it would take back files that were staged before.

**Show Conflicts becomes Resolve Conflicts.** It selects the row for uncommitted changes, as before, and then the first file under Conflicts.

## Consequences

- Writing a file in the worktree is new for Roga, which until now only changed files through git or the Trash. It writes only conflicted files, only from a button, and only over bytes it has just read.
- A file's conflicts are read in full, up to 16 MiB. A bigger file shows its patch.
- Markers are found by their shape, with seven characters or the size the first marker has, so a file whose `conflict-marker-size` attribute differs between markers isn't recognized. A stray `=======` outside a conflict, as in a Markdown heading, stays text.
- The sides are named from the first conflict's labels, which are the same for every conflict in a file.
- Edit… is a box under the button rather than the band turning into a text box in place, because the diff's text view can't be edited (decision 9). It's the part most likely to change.
- What both sides started from only shows when the repository's conflict style writes it into the file. Reading it from the index for the default style isn't built.
- The bands' buttons have no keyboard commands yet, and VoiceOver reaches them only as the buttons they are. Moving between conflicts would bring both, like moving between hunks.
- After a stash pop, Mark Resolved stages the file, and the stash stays until someone drops it, as decision 59 says. Unstaging it and dropping Roga's own stash once the last conflict is resolved, as the canvas drew, isn't built.
- Handing a file to an agent, option C, comes next. It would send each conflict, what both sides started from and both commits' messages to the agent the way Generate does ([decision 41](0041-agents-status-from-their-hooks-and-messages-from-their-clis.md)), with no tools, and show what came back with Show Sides, Undo for each conflict, and **Put Conflicts Back**, which runs `git checkout --merge`. The engine can already put conflicts back.
