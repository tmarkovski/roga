# 32. Ask before forcing a worktree with submodules

Accepted on 2026-11-04.

## Context

`git worktree remove` refuses any worktree with an initialized submodule, even a clean one, and says that "working trees containing submodules cannot be moved or removed". It isn't reacting to anything it found there, and `--force` is the only way past it. yaga only forced a worktree with uncommitted files, so deleting a clean worktree in a repository with submodules ended in a dialog that could only say **OK**, and the user had to finish from the command line. Agents' worktrees run into this often, because agents initialize submodules to build.

`--force` isn't free. It takes the submodule's files and its git directory, which lives in the worktree's own git directory at `worktrees/<id>/modules`. A commit on a side branch, a stash or an ignored file in there doesn't show up in `git status` in the main repository, and nothing else has a copy.

We looked at these:

- **Always forcing, without saying so.** This removes the error, but it can lose work without a word, which [the vision](../../VISION.md) rules out.
- **Running `git submodule deinit` first.** It leaves the `modules` folder behind, so git still refuses, and it refuses a dirty submodule itself.
- **Trying without force, and offering to force when git refuses.** This needs yaga to recognize git's message, which changes with the language and between versions, and the user only finds out after they've already answered any other question.
- **Looking inside each submodule, and asking only when something would be lost.** This fits the rule that a deletion asks only when something can't be brought back, but it means going through nested submodules and copies left by `deinit`, and yaga doesn't otherwise deal in submodules.
- **Detecting them and asking.** This is the one we chose.

## Decision

**yaga finds submodules before it runs anything, the two ways git does.** A worktree counts if its git directory has a `modules` folder, or if a submodule recorded in its index is checked out. A submodule that was never checked out in the worktree doesn't count, so that worktree still deletes straight away, as git allows.

**A worktree with submodules always asks.** The dialog says that git only removes it when forced, and that nothing has looked inside the submodules, so anything that's only there goes too. It names them in the same card as whatever else the deletion would lose. The command in the block has `--force`, in pink.

**The button says Delete anyway.** It's still red, and Return still doesn't press it. Other worktrees keep **Delete**.

**A lock still stops it.** A single `--force` doesn't get past `git worktree lock`, so a locked worktree with submodules gets git's refusal and no question, as any locked worktree does.

## Consequences

- Every worktree with a submodule checked out asks once, even when there's nothing in it to lose. Looking inside could take that question away later, and nothing here stands in the way of that.
- `git worktree remove` used to check again at the last moment for a clean worktree. With `--force` it doesn't, so a file written after the dialog opens goes without being mentioned. Worktrees with uncommitted files already worked this way.
- A worktree with uncommitted files was already forced, without a word about its submodules. Now it mentions them too.
- Preparing a deletion runs `git ls-files --stage`, which lists every file in the worktree, and one more `git rev-parse`. They only run when someone deletes a worktree.
- This isn't managing submodules, which the [roadmap](../../ROADMAP.md) leaves for its own decision. It only lets a command yaga already has finish.
