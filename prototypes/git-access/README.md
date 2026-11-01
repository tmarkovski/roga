# Git access prototype

This is a throwaway benchmark tool for deciding how yaga reads a Git repository. It isn't part of the app, and nothing in it should be copied into the app without being rewritten properly.

It compares three ways to load the history of `HEAD`:

- **`log-cli`** streams `git log` output and parses every commit.
- **`log-libgit2`** walks history with libgit2 and looks up every commit.
- **`log-graph`** reads git's commit-graph file directly to order the history and lay out the graph, then loads the author and subject only for the rows on screen. It gets them from a long-running `git cat-file --batch` process or from libgit2.

It also compares working tree status (`git status`, with and without the filesystem monitor, and libgit2) and full patches between two revisions (`git diff` and libgit2).

Its `render` command opens a window that shows the history in an AppKit `NSTableView`, a SwiftUI `List`, or a SwiftUI `LazyVStack`. It then measures how long each frame takes while it scrolls, jumps to random positions, inserts commits and selects rows.

Its `diff-render` command does the same for a diff between two revisions, shown in an `NSTableView` or in an `NSTextView` using TextKit 1 or TextKit 2.

Findings are in [RESULTS.md](RESULTS.md), and raw output is in [results/](results/).

## Running it

The tool needs libgit2 from Homebrew:

```bash
brew install libgit2
```

The script deletes and rewrites the repository's commit-graph file, so run it on clones made for benchmarking. The repository's root `.gitignore` excludes `bench-repos/` for that purpose:

```bash
git clone https://github.com/torvalds/linux.git bench-repos/linux
```

```bash
prototypes/git-access/run-benchmarks.sh bench-repos/linux v6.0 v6.1
```

The `render` command isn't part of the script, because each run opens a window on screen for about 15 seconds. It needs the commit-graph file that the script writes. Run it once for each view:

```bash
prototypes/git-access/.build/release/git-bench render --repo bench-repos/linux --engine table
```

Use `--engine list` or `--engine lazy-stack` for the SwiftUI views, and `--rows` to show only part of the history.

The `diff-render` command works the same way. By default it shows the whole diff from v6.0 to v6.1:

```bash
prototypes/git-access/.build/release/git-bench diff-render --repo bench-repos/linux --engine textkit1 --path drivers/net/wireless/realtek/rtw89/rtw8852c_table.c
```

Use `--engine table`, `--engine textkit1` or `--engine text` (TextKit 2), `--path` to show a single file, and `--wrap` or `--plain` to change how the text views lay out and color the diff.

Each subcommand can also be run on its own. Use `--help` to see the options:

```bash
swift run -c release --package-path prototypes/git-access git-bench --help
```

Set `GIT_BENCH_GIT` to benchmark a specific git binary instead of the first one on `PATH`.
