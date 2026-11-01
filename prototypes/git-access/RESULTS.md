# Results

These results answer the open question in the vision about how yaga should talk to Git. The short answer is to run the `git` binary for almost everything, read git's commit-graph file directly to get the shape of history, and not use libgit2.

## Setup

- An Apple M3 with 24 GB of memory, running macOS 27.0.1.
- git 2.52.0 from Homebrew and libgit2 1.9.7.
- The Linux kernel at `cbbddb6b08cc` (1,505,091 commits and 97,345 files), and git's own repository (82,634 commits and about 4,500 files).
- Every number is the median of three to five runs, with the files already in the operating system's cache, which matches reopening a repository you've used recently.

I left out Chromium because the machine had only 38 GB of free disk space. The raw output is in [results/linux.txt](results/linux.txt) and [results/git.txt](results/git.txt).

## History

"First screen" is the time from starting until 100 commits, with their authors and subjects, are ready to draw. "Whole history ordered" is the time until every commit has a row. For `git log` and libgit2 that includes the text of every commit. For the commit-graph reader it includes only the order, and the text is loaded for the rows on screen.

Linux kernel:

| Approach | Commit-graph file | First screen | Whole history ordered | Peak memory |
| --- | --- | ---: | ---: | ---: |
| `git log` (default order) | no | 27 ms | 12.3 s | 0.5 GB + 1.5 GB in git |
| `git log --date-order` | no | 8.8 s | 11.9 s | 0.5 GB + 3.1 GB in git |
| libgit2 revision walk | no | 16.5 s | 34.3 s | 2.5 GB |
| `git log --date-order` | yes | 27 ms | 11.9 s | 0.6 GB + 1.5 GB in git |
| libgit2 revision walk | yes | 17.1 s | 34.8 s | 2.4 GB |
| Commit-graph reader, text from `cat-file` | yes | 399 ms | 372 ms | 81 MB + 29 MB in git |
| Commit-graph reader, text from libgit2 | yes | 378 ms | 362 ms | 107 MB |

git's repository:

| Approach | Commit-graph file | First screen | Whole history ordered |
| --- | --- | ---: | ---: |
| `git log --date-order` | no | 423 ms | 552 ms |
| libgit2 revision walk | no | 574 ms | 679 ms |
| `git log --date-order` | yes | 12 ms | 626 ms |
| Commit-graph reader, text from `cat-file` | yes | 25 ms | 6 ms |

Writing the commit-graph file took 16.3 seconds for Linux and produced a 96 MB file. For git's repository it took 0.5 seconds and produced 4.9 MB.

Once the history was ordered, laying out the graph took about 0.5 seconds for all of Linux and 14 ms for git's repository. Linux's graph is up to 702 lanes wide in date order.

### What this shows

**Loading the text of every commit up front is too slow to do.** Every approach that reads the author and subject of all 1.5 million commits takes about 12 seconds with git, or about 35 seconds with libgit2, and holds between 0.5 and 2.5 GB of memory. The shape of the history is cheap, but the text is expensive. yaga should load the whole shape and only the text it's about to draw. A search across all commit messages needs the text too, but it can stream it in the background.

**The commit-graph file is what makes large histories fast.** With one, `git log --date-order` fills the first screen in 27 ms instead of 8.8 seconds, because git uses the generation numbers stored in the file to output commits in order without walking the whole history first. Reading the file directly orders all 1.5 million commits in 372 ms using 81 MB. The commit-graph reader returned exactly the same parents as git for every commit in both repositories. Its order differed from git's only at a handful of positions where commits share a timestamp (151 of 1.5 million positions on Linux).

**A fresh clone doesn't have a commit-graph file.** git doesn't write one when it clones. `git gc` and `git maintenance` write one later, so many repositories have one, but not all.

**Loading text for the rows on screen is cheap with either backend.** A long-running `git cat-file --batch` process returned the first 100 commits in 19 ms, including starting the process, and any later window of 100 rows in 1.4 ms. libgit2 took 7 ms for the first window. Both are well within one frame, so this isn't a reason to use libgit2.

**libgit2 doesn't use the commit-graph file when it walks history.** Its walk took 16 to 17 seconds to return the first commit whether or not the file existed.

## Status

| Approach | Linux | git's repository |
| --- | ---: | ---: |
| `git status --porcelain=v2` | 278 ms | 16 ms |
| Same, with the filesystem monitor and untracked cache | 51 ms | 23 ms |
| libgit2 | 422 ms (330 MB) | 19 ms |

The filesystem monitor and the untracked cache make status on Linux more than five times faster. yaga can turn them on for a single command with `-c core.fsmonitor=true -c core.untrackedCache=true`, without changing the user's configuration. But the first of these settings starts a filesystem monitor daemon for the repository that keeps running, and the second stores extra data in the index. On a small repository the pair made status slightly slower, so yaga would only want them for large ones.

Linux has 13 files whose names differ from another file's only in case. macOS's default file system is case-insensitive, so a fresh Linux checkout on a Mac shows those 13 as modified. git reported 13 entries, while libgit2 reported 26 for the same working tree. I didn't look into why, but it's the kind of disagreement with git that yaga can't afford.

## Diffs

The test was the full patch with rename detection, from Linux v6.0 to v6.1 (12,914 files, 1.29 million lines, and 45 MB of text), and from git v2.40.0 to v2.45.0 (1,649 files and 275,000 lines).

| Approach | Linux: first output | Linux: whole patch | git's repository: whole patch |
| --- | ---: | ---: | ---: |
| `git diff -M` | 173 ms | 2.6 s (777 MB in git) | 285 ms |
| libgit2 | 2.6 s | 7.0 s (766 MB) | 440 ms |

`git diff` streams the first file almost immediately. libgit2 finishes rename detection across the whole diff before it reports anything. Either way, a 45 MB patch is too much to load at once, so yaga should show the list of changed files first and load each file's patch when it's needed. I didn't measure that yet.

## Other findings

- **Launching git costs about 9 ms, but only without `Process.waitUntilExit()`.** Foundation's `waitUntilExit()` added 65 to 70 ms to every git command, even after git had exited, because it waits by polling a run loop. The prototype uses `posix_spawn` and `waitpid` instead, and the app should too.
- **Homebrew's libgit2 is built for macOS 27**, so linking it into an app that supports macOS 26 would mean building libgit2 ourselves.
- **Graph layout needs design work.** At 702 lanes, Linux's graph can't be drawn literally. The UI needs a way to collapse or compress lanes. Layout runs in order from the top, so the first screen only needs the first rows laid out.

## Recommendation

1. **Run the `git` binary** for everything that writes to the repository or uses the network, and for status, diffs, and the first screen of history (`git log --date-order`).
2. **Read the commit-graph file directly** for the order and layout of the whole history, along with jumps, the scrollbar and ancestry questions. When there's no commit-graph file, or it's missing newer commits, fall back to git and write or update the file in the background, the same way `git gc` would.
3. **Keep a long-running `git cat-file --batch` process** for the text of the commits being drawn.
4. **Don't use libgit2.** It was slower on every large-repository test, it disagreed with git about status, and it brings a dependency that we'd have to build ourselves.

This fits the existing decision to use the user's git (decision 3). It does make the minimum git version matter. The features above suggest that git 2.36, the release that brought the built-in filesystem monitor to macOS, is a reasonable minimum.

The real commit-graph reader would also need to handle things the prototype skips:

- split commit-graph chains, which `git maintenance` and `fetch.writeCommitGraph` create
- commits newer than the file
- repositories that use SHA-256

## Not tested yet

- Drawing a million rows: whether a SwiftUI `List` can do it or the graph needs AppKit.
- Loading a large diff one file at a time.
- Searching across all commit text.
- A cold file cache, Apple's git 2.54.0, and a second very large repository such as Chromium.
