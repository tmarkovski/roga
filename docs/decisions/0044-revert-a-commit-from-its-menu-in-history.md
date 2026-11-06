# 44. Revert a commit from its menu in history

Accepted on 2026-11-06.

## Context

Undoing a commit that's already been shared means reverting it: making a new commit that takes the old one's changes back out. Roga had no way to do that, so it took the command line, even though history is where people find the commit. A commit's menu only offered **Delete…**, and only for a commit with a branch that could go ([decision 38](0038-one-delete-on-a-commit-with-its-branches-in-the-dialog.md)), so most rows had no menu at all (https://github.com/tmarkovski/yaga/issues/16).

[ROADMAP.md](../../ROADMAP.md) keeps what release 1 changes in a repository to a short list of exceptions, so this is another one, like deleting branches and committing before it.

Before deciding, we checked what Apple's git 2.54 does in scratch repositories:

- **A committing revert refuses while anything is staged**, even a file the commit never touched, with "your local changes would be overwritten by revert", and nothing changes. Unstaged changes elsewhere are fine, but unstaged changes to a file the commit touched make both kinds refuse.
- **`--no-commit` adds to what's staged.** It leaves `REVERT_HEAD`, and git's message in `MERGE_MSG`, until the next commit, which clears both, including one made with `git commit -F -` the way Roga commits. Nothing in Roga read `REVERT_HEAD`, so [decision 28](0028-show-a-worktree-thats-stuck-partway.md) showed such a worktree as just its conflicts, or as nothing at all.
- **`git revert --abort` takes everything staged back to `HEAD`**, in the index and in the files, because it runs `git reset --merge`. That includes whatever was staged before the revert began. If one of those files has unstaged changes on top, it refuses and nothing changes. `git revert --quit` would forget the revert and keep everything staged.
- **git commits a revert without the pre-commit and commit-msg hooks**, whether they're files or set up in the config. It does run prepare-commit-msg and post-commit.
- **A merge needs `-m`** to say which parent's side to keep, and git refuses one without it.
- **git reverts a commit that `HEAD` doesn't contain** by taking its changes out of whatever `HEAD` has. That can do nothing, apply part of it or stop on conflicts.
- **When there's nothing to revert**, as with a commit that's already been reverted, git stops with "nothing to commit" on its standard output and nothing on its standard error, which is where Roga had looked for what git said.
- **A conflict stops with status 1**, leaving `REVERT_HEAD` and `MERGE_MSG`, whose `# Conflicts:` lines are comments that the commit box already leaves out.

How the dialog holds the choice:

- **A switch for committing.** This is how [decision 33](0033-one-row-in-a-menu-and-the-choice-in-the-dialog.md) holds what else goes with a deletion. But here the two choices are two different results rather than one thing going further, and a switch with one button reads as a setting.
- **Rows or pictures, as rebase or merge has.** There's no shape to draw that says more than the words, and it's the tallest.
- **The choices as buttons, with the block showing what the button under the pointer runs.** That's how [decision 37](0037-double-click-a-commit-to-go-to-it.md)'s reset dialog offers **Keep changes**. This is the one we chose.

For merges, we could revert against the first parent or leave merges out of the first version. On a branch that takes pull requests as merge commits, a merge is the commit someone most often wants to revert, so leaving merges out would leave out the usual case.

For a commit that `HEAD` doesn't contain, we could disable the row or warn in the dialog. The menu is built the moment someone right-clicks, so it can't wait for git to say whether `HEAD` contains the commit. And there's a real use for reverting one: a change that reached `HEAD` as a cherry-pick has another hash, and reverting the original still takes it out.

## Decision

**Every commit's menu has Revert…**, above **Delete…** when the commit has a branch that could go. So every commit row now has a menu. It's disabled while the worktree is partway through a merge, a rebase or a revert, and while git is running something else. git can stack a revert left uncommitted on another one, but that's rare enough to leave to the command line.

**It runs in the worktree on screen, against its `HEAD`**, like the title row's commands.

**One dialog holds the choice, in its buttons.** It's titled **Revert 98c48e97?**, says what it undoes on which branch, and shows the commit in a card. **Commit the revert** runs `git revert --no-edit <hash>` and is ink, so Return presses it. **Leave it uncommitted** runs `git revert --no-commit <hash>`. The block shows the default's command, and the other's while the pointer is on its button. The dialog is also the confirmation, so nothing asks again.

**With something staged, it starts on Leave it uncommitted.** It reads what's staged afresh when the dialog opens rather than trusting the last look. It says how many files are staged, and that git only commits a revert when nothing is, so this adds the reversed changes to them. **Commit the revert** is disabled, and **Leave it uncommitted** is ink. Unstaged changes in the commit's own files aren't caught ahead of time: git refuses, and a dialog shows what it said and that nothing changed.

**A merge is reverted against its first parent**, with `-m 1`, and the dialog says which side it keeps and which commit's side it takes out. It also says that git still counts those commits as merged, so merging them again won't bring them back, which is the part of reverting a merge that catches people.

**A commit that `HEAD` doesn't contain gets a warning, not a disabled row.** The dialog checks with `git merge-base --is-ancestor`, says what git will do and that it only makes sense when the changes got to `HEAD` another way, such as a cherry-pick. Return presses neither button then, so it takes a click. `DialogButton` has `pressesWithReturn` for that.

**It says when git will leave out the commit hooks.** When the repository has a pre-commit or commit-msg hook, where git looks for one or in its config, a note says that git commits a revert without them, and that they run when you commit from the box.

**Leaving it uncommitted ends in the commit box.** The row for uncommitted changes is selected, and the box starts with git's message from `MERGE_MSG`, as it does for a merge. It doesn't replace a draft someone already typed. The heading says **Commit revert**, and the button **Commit Revert**. Committing from the box runs the user's hooks and finishes the revert.

**A revert that's underway shows the way a merge does**, whoever started it ([decision 28](0028-show-a-worktree-thats-stuck-partway.md)). The title row reads **⚠ Reverting 98c48e97 · 2 conflicts** in red, or **Reverting 98c48e97 · ready to commit** in gray, and so do the row for uncommitted changes and the menu of worktrees. It goes by the commit's short hash rather than its subject, because the sidebar reads this from files without running git, and a subject can be as long as the title row. The subject is in the tooltip. `StoppedWork` has a revert, read from `REVERT_HEAD` in the same `git rev-parse` as the others, and from the file for the sidebar.

**Abort Revert… says that everything staged goes.** It runs `git revert --abort`, and its dialog says that everything staged goes back to `HEAD`, in the index and in the files, including anything that was staged before the revert, with a card counting the staged files. The button is red, as aborting a merge or a rebase is.

**A revert that stops on a conflict asks what to do**, as a pull does: **The revert stopped on a conflict**, with its files, **Leave it** and **Undo the revert**. When the revert was left uncommitted on top of staged files, it says that undoing it takes those back too, and **Undo the revert** turns red.

**A failure shows what git said, wherever it said it.** When git stops with nothing to revert, it has only said why on its standard output, so that's what the dialog shows.

## Consequences

- Each look at the selected worktree asks `git rev-parse` for one more path. While a revert is underway, it also reads the commit's subject, for the tooltip. The sidebar checks one more file for each worktree, and runs nothing new.
- **Commit the revert** leaves out the pre-commit and commit-msg hooks, so a check that a team relies on doesn't see the commit. The note says so, but only Leave it uncommitted and the box avoid it.
- Aborting a revert that was added to staged files loses those files' changes, from the index and from disk. Roga says so first, but can't prevent it. `git revert --quit` would keep them, and Roga doesn't offer it.
- When there's nothing to revert, git leaves a `MERGE_MSG` behind, and Roga leaves it there. The next `git commit` at the command line starts its message from it.
- The row stays enabled for a commit that `HEAD` doesn't contain, so a slip opens the dialog. It takes a click to go further.
- Conflicts from a cherry-pick still read just **2 conflicts**, with nothing to abort, because nothing reads `CHERRY_PICK_HEAD` yet. It would be the same few lines as a revert.
- Reverting a root commit usually stops on conflicts, because git takes every file it added back out, against whatever has changed them since.
- Reverting several commits at once, or a range, takes the command line.
