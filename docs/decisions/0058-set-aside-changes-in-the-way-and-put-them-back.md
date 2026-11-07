# 58. Set aside changes in the way, and put them back

Accepted on 2026-11-07. This changes what [decision 19](0019-pull-and-push-from-the-branch-in-the-title-row.md) says about a pull that git refuses, and what [decision 37](0037-double-click-a-commit-to-go-to-it.md) says about uncommitted changes that are in the way of going to a commit.

## Context

Clicking `↓` on `main` showed "Can't pull main", because `docs/main-window.md` had uncommitted edits and the commits coming in changed it too. `git pull --ff-only` won't overwrite a file with local changes, and neither will `git reset --keep`, so double-clicking `origin/main`'s row failed the same way. Both dialogs said nothing had changed, which was true, but the only way on was the command line: stash, pull, pop. An orange `↓` is supposed to mean that a click runs now.

The options we drew on the design canvas, on the page "Changes in the way":

- **Leave it to git.** That's the dead end above.
- **`git pull --autostash`.** It works for a pull, but `reset` and `switch` have no such flag. It stashes whenever anything is uncommitted, even when nothing is in the way, which rewrites files under the user's editor and agents. When the changes don't fit back, it leaves conflict markers in a stash named "autostash", and it puts them back without `--index`, so whatever was staged comes back unstaged.
- **Ask first, when putting them back would conflict.** `git merge-tree` can tell ahead of time, and the dialog would offer to put them back anyway or leave them stashed. We drew it with two buttons and with pictures.
- **Always set them aside and put them back, and stop on a conflict like any pull that hits one.** This is the one we chose. Trying loses nothing, because the stash keeps a copy, so a question beforehand only gets in the way.

## Decision

**Changes go aside only when they're in the way.** Before a pull or going to a commit, Roga compares the tracked files with uncommitted changes against the files the move changes: what the upstream changed since the two lines parted, for a pull, or everything between `HEAD` and the commit, for going to one. When none overlap, the command runs as it always did, because git takes the changes along. A rebase is different, because git refuses to start one with any uncommitted change, so for a pull that rebases everything goes aside. A fast-forward counts as a rebase when `pull.rebase` is set, because git refuses it the same way. Untracked files stay where they are, and Keep changes, which runs `git reset --soft`, never needs it.

**Everything uncommitted goes aside, not only what's in the way.** `git stash push --message "Roga: before pulling main"` takes all of it, so that undoing can throw the worktree away and lose nothing. Its message names the move, so that someone who finds it in Stashes knows where it came from.

**Then Roga moves and puts the changes back.** It finds the stash by its hash rather than assuming it's the newest, and runs `git stash pop --index`, which brings back what was staged too. The title row says **Pulled · your changes are back**, and going to a commit says **Your changes are back**. If git refuses the move, the changes go straight back, and the dialog is the same refusal as before.

**When they come back with conflicts, Roga stops, as a pull that hits a conflict does.** A dialog, **Putting your changes back stopped on a conflict**, names the files and offers **Leave it** and **Undo the pull**. Undo is ink and Return presses it, because it's the way out. Leave it leaves the files with conflict markers and the title row reading **⚠ 1 conflict**, as it already does for a `git stash pop` that conflicts. Roga can't resolve conflicts yet, so that means the editor or the command line. git keeps the stash after a conflict, so it stays in Stashes until someone drops it.

**Undo can't abort, because git has no abort for a stash.** It runs `git reset --hard` to where `HEAD` was, or `git switch --discard-changes` back to the branch after detaching, and then pops the stash there. The stash was made on that commit, so it always fits, and the worktree ends up exactly as it was, staging included. The block shows `--hard` in pink, as any command that throws work away, but the button is ink, because the stash has all of it.

**Staging comes back as it was, even after a conflict.** When git stops on a conflict, it stages every file that came back cleanly. Roga unstages the ones that weren't staged before, and gives a file that the move didn't touch exactly what was staged, from the stash's index. A file the move did change stays wholly staged, because what was staged was against the old commit.

**A pull that stops on its own conflict keeps the changes aside.** If a merge or a rebase stops partway, the changes stay in the stash, and the dialog for the pull's conflict says where they are. Undoing the pull aborts it, resets, and pops them back.

**When git won't put them back, they stay in the stash.** An agent can write to one of the files between the stash and the pop, and git then refuses to overwrite it. A dialog, **Your changes are still in a stash**, names the stash and shows what git said, and nothing is lost.

## Consequences

- An agent's file watcher sees the stashed files change twice, once when they go aside and once when they come back. That only happens when something was in the way, so a pull that git would take anyway rewrites nothing.
- A file that the move changed and that was partly staged comes back wholly staged after a conflict.
- An untracked file that a pull would add is still a refusal. Moving it to the Trash first, as discarding does ([decision 39](0039-discard-with-undo-and-ask-only-for-many.md)), was sketched but isn't built.
- Checking out a branch still refuses when changes are in the way. It could set them aside the same way.
- What's in the way is worked out against the remote branch as of the last fetch. A pull fetches first, so commits it brings in that change other files can still make git refuse.
- After Leave it, the stash stays until someone drops it, because it's the only copy of the changes as they were.
- A screen for resolving conflicts would serve merges, rebases, reverts and stash pops alike, and is its own exploration on the design canvas.
