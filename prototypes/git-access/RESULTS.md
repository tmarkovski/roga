# Results

These results answer two questions. The first is the open question in the vision about how Roga should talk to Git. The short answer is to run the `git` binary for almost everything, read git's commit-graph file directly to get the shape of history, and not use libgit2. The second is whether SwiftUI can show the history of a very large repository. It can scroll through it smoothly, but every change to the data or the selection freezes the app for a time that grows with the number of commits, so the commit list should be an AppKit `NSTableView`. That second answer is in [Drawing the history](#drawing-the-history). A third section, [The diff view](#the-diff-view), compares an `NSTableView` with TextKit 1 and TextKit 2 for showing large diffs.

## Setup

- An Apple M3 with 24 GB of memory, running macOS 27.0.1.
- git 2.52.0 from Homebrew and libgit2 1.9.7.
- The Linux kernel at `cbbddb6b08cc` (1,505,091 commits and 97,345 files), and git's own repository (82,634 commits and about 4,500 files).
- Every number is the median of three to five runs, with the files already in the operating system's cache, which matches reopening a repository you've used recently.
- The Git access benchmarks ran on battery power with Low Power Mode off. Spot checks repeated on AC power matched them.

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

**Loading the text of every commit up front is too slow to do.** Every approach that reads the author and subject of all 1.5 million commits takes about 12 seconds with git, or about 35 seconds with libgit2, and holds between 0.5 and 2.5 GB of memory. The shape of the history is cheap, but the text is expensive. Roga should load the whole shape and only the text it's about to draw. A search across all commit messages needs the text too, but it can stream it in the background.

**The commit-graph file is what makes large histories fast.** With one, `git log --date-order` fills the first screen in 27 ms instead of 8.8 seconds, because git uses the generation numbers stored in the file to output commits in order without walking the whole history first. Reading the file directly orders all 1.5 million commits in 372 ms using 81 MB. The commit-graph reader returned exactly the same parents as git for every commit in both repositories. Its order differed from git's only at a handful of positions where commits share a timestamp (151 of 1.5 million positions on Linux).

**A fresh clone doesn't have a commit-graph file.** git doesn't write one when it clones. `git gc` and `git maintenance` write one later, so many repositories have one, but not all.

**Loading text for the rows on screen is cheap with either backend.** A long-running `git cat-file --batch` process returned the first 100 commits in 19 ms, including starting the process, and any later window of 100 rows in 1.4 ms. libgit2 took 7 ms for the first window. Both are well within one frame, so this isn't a reason to use libgit2.

**libgit2 doesn't use the commit-graph file when it walks history.** Its walk took 16 to 17 seconds to return the first commit whether or not the file existed.

## Status

| Approach | Linux | git's repository |
| --- | ---: | ---: |
| `git status --porcelain=v2` | 251 ms | 16 ms |
| Same, with the untracked cache | 103 ms | not measured |
| Same, with the filesystem monitor and the untracked cache | 51 ms | 23 ms |
| libgit2 | 422 ms (330 MB) | 19 ms |

The first two Linux rows come from a later run on AC power, after I noticed that the cache had changed the results. The first run recorded 278 ms for plain status, but by then the untracked cache was already saved in the index.

The two settings work differently:

- **The untracked cache** is extra data that git saves in the index. Once it's there, git keeps using it by default, even for commands that don't ask for it. It needs no background process, and it alone made status on Linux about two and a half times faster.
- **The filesystem monitor** starts a daemon for the repository that keeps running. Together with the untracked cache, it made status on Linux about five times faster.

Roga can turn either one on for a single command, for example with `-c core.untrackedCache=true`, without changing the user's configuration. On a small repository the pair made status slightly slower, so Roga would only want them for large ones. Whether Roga uses them is a separate decision.

Linux has 13 files whose names differ from another file's only in case. macOS's default file system is case-insensitive, so a fresh Linux checkout on a Mac shows those 13 as modified. git reported 13 entries, while libgit2 reported 26 for the same working tree. I didn't look into why, but it's the kind of disagreement with git that Roga can't afford.

## Diffs

The test was the full patch with rename detection, from Linux v6.0 to v6.1 (12,914 files, 1.29 million lines, and 45 MB of text), and from git v2.40.0 to v2.45.0 (1,649 files and 275,000 lines).

| Approach | Linux: first output | Linux: whole patch | git's repository: whole patch |
| --- | ---: | ---: | ---: |
| `git diff -M` | 173 ms | 2.6 s (777 MB in git) | 285 ms |
| libgit2 | 2.6 s | 7.0 s (766 MB) | 440 ms |

`git diff` streams the first file almost immediately. libgit2 finishes rename detection across the whole diff before it reports anything. Either way, a 45 MB patch is too much to load at once, so Roga should show the list of changed files first and load each file's patch when it's needed. I didn't measure that yet.

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

## Drawing the history

The `render` command opens a window that shows Linux's 1,505,091 commits in one of three views:

- an AppKit `NSTableView` whose rows draw themselves
- a SwiftUI `List`
- a SwiftUI `LazyVStack` inside a `ScrollView`

The order and lanes are real, from the commit-graph reader. Each row draws up to 20 lane lines, a dot for the commit, a subject, an author and a date. The text is generated, so the test measures drawing and not loading. In the SwiftUI views, every row has a stable ID based on its commit, the way the app would identify it.

A display link drives each run and records the time until every frame. The driver scrolls the view's underlying `NSScrollView` directly, the way a trackpad does, so all three views are measured the same way. Each run goes through four steps:

1. It scrolls steadily at 6,000 points per second for 5 seconds.
2. It jumps to 20 random positions, as if someone dragged the scrollbar.
3. It inserts 10 new commits at the top five times, as a fetch would.
4. It selects a visible row five times.

The display runs at 60 Hz, so one frame lasts 16.7 ms, and anything noticeably longer means the app visibly stalled. The raw output is in [results/render-linux.txt](results/render-linux.txt).

| Step | `NSTableView` | SwiftUI `List` | SwiftUI `LazyVStack` |
| --- | ---: | ---: | ---: |
| Steady scrolling, longest frame | 17 ms | 18 ms | 17 ms |
| Jump to a random position, longest | 16 ms | 26 ms | 42 ms |
| Insert 10 commits at the top, median | 24 ms | 453 ms | 574 ms |
| Select a visible row, median | 17 ms | 413 ms | 17 ms |
| Peak memory, including about 250 MB for the history itself | 255 MB | 380 MB | 301 MB |

Each view drew between 2,150 and 2,530 rows during its run, and the scrolled content was 33.1 million points tall in all three. That confirms that the driver really scrolled each view.

The cost in the SwiftUI `List` grows with the number of rows:

| Rows | Insert 10 commits, median | Select a row, median |
| ---: | ---: | ---: |
| 100,000 | 92 ms | 68 ms |
| 500,000 | 183 ms | 167 ms |
| 1,505,091 | 453 ms | 413 ms |

### What this shows

**All three views scroll smoothly through 1.5 million rows.** On macOS, a SwiftUI `List` is built on `NSTableView` underneath, and it creates rows only as they come into view.

**Every change to the list's data freezes SwiftUI for a time that grows with its size.** Inserting commits, which happens after every fetch, froze the `List` for about half a second at Linux's size and for about a tenth of a second at 100,000 commits. SwiftUI compares the identities of every row each time the collection changes. `NSTableView` only does the work for the rows that changed.

**Selection in a SwiftUI `List` costs about the same as a data change.** Selecting a row in the `List` froze it for 413 ms. The `LazyVStack` selected rows in one frame because each visible row checked the selection itself, so a selection change only redrew those rows. Even so, its inserts were the slowest of the three.

**The commit list should be an `NSTableView`.** SwiftUI can still be used for the rest of the window, and the table can be placed in a SwiftUI layout with `NSViewRepresentable`. Working around the SwiftUI costs would mean giving SwiftUI only a window of rows and faking the full height, which rebuilds what `NSTableView` already does.

### Limits

- The display ran at 60 Hz. A 120 Hz display halves the time available for each frame. The table's frames stayed far under even that budget, but I didn't measure on one.
- The graph is simplified: rows draw straight lane lines and a dot, without the curves where branches merge.
- The text in each row is generated, so the cost of loading real commit text while scrolling isn't included. The Git access results showed that loading a screen of commits from `cat-file` takes 1.4 ms.

## The diff view

The test diff runs from Linux v6.0 to v6.1. It changes 12,914 files and 1.29 million lines, which comes to 45 MB of patch text. The file with the largest patch is `drivers/net/wireless/realtek/rtw89/rtw8852c_table.c`, with 27,113 lines added and 9,879 removed. Its patch is 40,325 lines long, and many of its removed and added lines pair up, so it exercises highlighting of changed words.

### Getting the diff from git

| What | Time |
| --- | ---: |
| List of changed files with renames (`git diff --raw -M`) | 175 ms (2.8 s on the first, cold run) |
| The same list with line counts (`git diff --numstat -M`) | 1.6 s |
| The patch for the largest file | 31 to 82 ms |
| The whole patch | 2.6 s (6.4 s on the first, cold run) |

Splitting the whole patch into lines took 142 ms.

### Drawing it

The `diff-render` command shows a diff in one of three ways:

- **An `NSTableView`** with one self-drawn row per diff line, the same approach decision 7 chose for the commit list. Rows show old and new line numbers, a full-width background for added and removed lines, and a darker background behind the changed part of a line.
- **An `NSTextView` using TextKit 2**, with the whole diff as one attributed string. Added and removed lines get background colors, and so do the changed parts.
- **An `NSTextView` using TextKit 1** with non-contiguous layout turned on, so it lays out only what's visible. The attributed string is the same as for TextKit 2.

Each view went through the same scrolling and jumping steps as the commit list test. The text views had no line numbers, and their backgrounds covered only the text, not the full width of the line. The raw output is in [results/diff-render-linux.txt](results/diff-render-linux.txt).

For the largest file:

| Setup | Preparing the view | Longest frame while scrolling | Jumps, median and longest | Peak memory |
| --- | ---: | ---: | ---: | ---: |
| `NSTableView` | 2 ms | 19 ms | 16 ms, 16 ms | 180 MB |
| TextKit 1, non-contiguous layout | 58 ms | 25 ms | 6 ms, 17 ms | 144 MB |
| TextKit 2, lines wrapped | 60 ms | 33 ms | 17 ms, 313 ms | 170 MB |
| TextKit 2, unwrapped, view sizes its own width | 1,098 ms | 1,033 ms | 633 ms, 912 ms | 453 MB |
| Same, without any background colors | 830 ms | 817 ms | 533 ms, 717 ms | 389 MB |
| TextKit 2, unwrapped, fixed 20,000-point width | 1,063 ms | 138 ms | 17 ms, 133 ms | 325 MB |

For the whole diff as one document:

| Setup | Preparing the view | Longest frame while scrolling | Jumps, median and longest | Peak memory |
| --- | ---: | ---: | ---: | ---: |
| `NSTableView` | 1 ms | 17 ms | 16 ms, 16 ms | 273 MB |
| TextKit 1, non-contiguous layout | 1,102 ms | 30 ms | 11 ms, 23 ms | 495 MB |
| TextKit 2, lines wrapped | 1,162 ms | 33 ms | 17 ms, 167 ms | 474 MB |

### What this shows

**TextKit 2 handles unwrapped text badly.** A diff of code usually shouldn't wrap. When the text view sized its own width, TextKit 2 took a second to prepare a 40,000-line file and stalled for up to a second while scrolling, even without any colors. A fixed width cut the stalls to about 140 ms, but preparing still took a second and memory was twice that of TextKit 1. With wrapping on, it performed about as well as TextKit 1.

**TextKit 1 with non-contiguous layout works well at every size we tried.** For the largest file it prepared in 58 ms and scrolled smoothly. For the whole diff it scrolled smoothly too, but it spent 1.1 seconds building the attributed string first and used almost twice the memory of the table.

**The table costs nothing up front.** It draws each line from the parsed bytes when the line comes into view, so it needed 1 ms to prepare even the whole diff, and it used the least memory at that size.

**What the text views give for free, the table would have to build.** An `NSTextView` provides text selection across lines, copying, the find bar, and VoiceOver support. With a table, Roga would have to write all of that itself. In return, the table makes full-width line backgrounds and line numbers simple, while the text views need extra drawing code for both.

**Two TextKit details matter for the real app:**
- Asking a TextKit 2 `NSTextView` for its `layoutManager` silently switches it to TextKit 1. My first TextKit 2 run did exactly that by accident.
- The text views only estimate the full height of a large document, at roughly half the real height here. So the scrollbar's size and position shift as the user scrolls through a huge diff.

### Recommendation

Use a TextKit 1 `NSTextView` with non-contiguous layout for the diff content. Show the changed files in a list, and load the patch for the selected file or files into the text view, as the roadmap already plans. At the sizes that approach produces, TextKit 1 prepares in tens of milliseconds even for the largest file in this release. It also gives selection, copying, find and accessibility without any custom code, which matters for a view whose whole purpose is reading code. Line numbers and full-width backgrounds need some custom drawing, through a ruler view and a layout manager subclass.

The main risk is that TextKit 1 is the older text system and Apple's direction is TextKit 2. TextKit 1 is still fully supported, and the choice should be revisited if TextKit 2's handling of unwrapped text improves. If Roga ever needs to show a diff as large as a whole Linux release in one continuous view, the table remains the faster option, at the cost of building selection and find ourselves.

### Limits

- The text views had no line numbers, and their backgrounds covered only the text. Adding both will cost some drawing time that wasn't measured.
- Selecting all text, copying, and searching with the find bar weren't measured on a large diff.

## Not tested yet

- Searching across all commit text.
- A cold file cache, Apple's git 2.54.0, a 120 Hz display, and a second very large repository such as Chromium.
