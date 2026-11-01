# 5. Read history from the commit-graph file and run git for everything else

Accepted on 2026-11-01.

## Context

The vision left open how yaga talks to Git: by linking libgit2, by running the `git` binary, or by combining the two. The [Git access prototype](../../prototypes/git-access/RESULTS.md) measured these approaches on the Linux kernel (1.5 million commits and 97,000 files) and on git's own repository. On Linux, it found the following:

- Loading the author and subject of every commit up front took about 12 seconds with `git log` and about 35 seconds with libgit2, and used between 0.5 and 2.5 GB of memory.
- With a commit-graph file, `git log --date-order` filled the first screen in 27 ms instead of 8.8 seconds. Reading the file directly ordered the entire history in 372 ms using 81 MB, with parents identical to git's for every commit.
- A long-running `git cat-file --batch` process loaded the text for a screen of 100 commits in 1.4 ms.
- libgit2 was slower on every large-repository test. Its history walk took about 17 seconds and ignored the commit-graph file. Status took 422 ms against 51 ms for `git status` with the filesystem monitor, and the first diff output took 2.6 seconds against 173 ms. It also reported different status results from git for the same working tree.
- Foundation's `Process.waitUntilExit()` added 65 to 70 ms to every git command.

## Decision

- yaga runs the user's git (see decision 3) for everything that writes to the repository or uses the network, and for status, diffs, and the first screen of history.
- yaga reads git's commit-graph file directly to order and lay out the whole history, and to answer questions about ancestry.
- yaga keeps a long-running `git cat-file --batch` process to load the text of the commits it's about to draw. It loads commit text only for rows it shows. Features that need all of it, such as searching commit messages, stream it in the background.
- yaga doesn't use libgit2.
- yaga starts git with `posix_spawn` and waits for it with `waitpid`, not with Foundation's `Process`.

## Consequences

- yaga's commit-graph reader has to handle cases the prototype skipped:
  - split commit-graph chains
  - commits newer than the file
  - repositories that use SHA-256
  - repositories where git doesn't use a commit-graph file at all, such as shallow clones, repositories with replace refs, and repositories with `core.commitGraph=false`

  Each of these needs a fallback that asks git directly.
- Large repositories without a commit-graph file are slow to open until one exists. Decision 6 covers how yaga keeps the file up to date.
- yaga has no C library dependency for Git access, so the build stays plain Swift.
- yaga depends on the stability of git's machine-readable output: `--porcelain=v2`, `-z`, `--format`, and `cat-file --batch`. These formats are designed to stay stable, but yaga's tests should run against both the oldest and the newest supported git.
- The minimum git version needs to cover the features above. git 2.36 is the current candidate, because it brought the built-in filesystem monitor to macOS.
