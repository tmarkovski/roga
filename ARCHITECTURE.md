# Architecture

This document describes how yaga is put together: how the code is organized, which module owns what, how data moves from git to the screen, and the rules that keep the app fast. It builds on the [decisions](docs/decisions/README.md), which explain why each choice was made, and on what the [prototypes](prototypes/) measured. When the code and this document disagree, one of them needs fixing.

## The shape of the app

yaga is a Swift app for macOS 26 and later (decision 2). It runs the user's own git (decisions 3 and 8) and reads git's commit-graph file directly to order history (decisions 5 and 6). The window is SwiftUI, except for the two views that have to handle very large amounts of data: the commit list is an AppKit `NSTableView` (decision 7), and the diff is a TextKit 1 `NSTextView` (decision 9).

A window has a sidebar that lists every repository the user has added, with its worktrees under it, and there can be several windows (decisions 10, 13 and 14). Each repository has one session, which owns everything yaga knows about it, such as its git processes, its file watcher and its caches. Sessions don't depend on windows, so two windows that show the same repository share one session.

From the bottom up, the code is in these layers:

1. **Git itself.** This layer covers the object IDs, refs, commits, status entries and diffs that yaga works with, and parsers for the git output that describes them.
2. **Running git and reading its files.** One module starts git processes, and another reads commit-graph files and lays out history.
3. **Repository sessions.** This layer loads and caches what each repository contains, watches it for changes, and publishes snapshots.
4. **Views.** The commit list and the diff view are AppKit. The window, the sidebar, the refs panel, details and settings are SwiftUI.
5. **The app target.** This holds the entry point, Sparkle, and the resources that only an app bundle can have.

## Project layout

The Xcode project contains only the app target, and it's saved in Xcode's JSON format. Everything else is in a local Swift package called YagaKit, which the app depends on (decision 11). The package and its modules exist, but most of the files below are still to be written. Their names show where things go and will change as the code is written.

```text
yaga/
├── Yaga.xcodeproj/                 JSON project file (project.xcproj) with only the app target
├── App/                            the app target
│   ├── YagaApplication.swift       entry point, scenes, Sparkle updater
│   ├── CheckForUpdatesButton.swift
│   ├── Info.plist                  Sparkle's feed address and public key
│   └── Assets.xcassets             the app icon, once there is one
├── YagaKit/                        the local Swift package
│   ├── Package.swift
│   ├── Sources/
│   │   ├── GitCore/
│   │   │   ├── ObjectID.swift          SHA-1 and SHA-256 object IDs
│   │   │   ├── ObjectType.swift        commit, tree, blob and tag
│   │   │   ├── Refs.swift              refs, and what HEAD points to
│   │   │   ├── Worktree.swift          a worktree's folder, HEAD and branch
│   │   │   ├── CommitInfo.swift        a commit's parents, author, committer and message
│   │   │   ├── WorktreeChanges.swift   what's uncommitted in a worktree, in groups
│   │   │   ├── DiffFile.swift          a file a diff changes, and the lines added and removed
│   │   │   ├── FilePatch.swift         what a patch changes in a file, line by line
│   │   │   └── Parsing/                one parser per git output format
│   │   │       ├── ParseError.swift
│   │   │       ├── CommitParser.swift      commit objects from cat-file
│   │   │       ├── RefListParser.swift     for-each-ref
│   │   │       ├── ShowRefParser.swift     show-ref, for HEAD and what annotated tags lead to
│   │   │       ├── WorktreeListParser.swift worktree list --porcelain -z
│   │   │       ├── StatusParser.swift      status --porcelain=v2 -z, and --numstat -z
│   │   │       ├── RawDiffParser.swift     diff-tree --raw --numstat -z
│   │   │       └── PatchParser.swift       the hunks that diff-tree -p prints
│   │   ├── GitRunner/
│   │   │   ├── Git.swift               running a command, which every git command goes through
│   │   │   ├── GitInstallation.swift   finding git and checking its version
│   │   │   ├── GitVersion.swift        reading git version and the 2.44 minimum
│   │   │   ├── LoginShellPath.swift    the PATH from the user's login shell
│   │   │   ├── Spawn.swift             posix_spawn, process exit, stopping a process group
│   │   │   ├── Pipes.swift             reading and writing pipes with DispatchIO
│   │   │   ├── GitCommand.swift        the arguments, options and environment of one command
│   │   │   ├── GitOutput.swift         streaming output as an async sequence, and splitting it into records
│   │   │   ├── CatFileSession.swift    long-running cat-file --batch-command
│   │   │   └── CommandLog.swift        every git command yaga ran
│   │   ├── CommitGraph/
│   │   │   ├── CommitGraph.swift       positions, parents and dates, and commits newer than the files
│   │   │   ├── CommitGraphFile.swift   one mapped commit-graph file
│   │   │   ├── CommitGraphChain.swift  finding the single file or the split chain
│   │   │   ├── HistoryOrder.swift      date order and topological order, a few rows at a time
│   │   │   ├── LaneLayout.swift        the graph's lines in each row, with long ones cut
│   │   │   └── WorkingTreeLine.swift   the line from uncommitted changes down to HEAD
│   │   ├── RepositoryEngine/
│   │   │   ├── RepositoryLocation.swift where a repository's files are, and its hash
│   │   │   ├── RepositorySession.swift one actor per repository, which its worktrees share
│   │   │   ├── HistoryLoader.swift     commit-graph, newer commits, fallbacks
│   │   │   ├── RefsLoader.swift
│   │   │   ├── ChangesLoader.swift     a worktree's uncommitted files, and their patches
│   │   │   ├── BranchCheckout.swift    putting a worktree on a branch or remote branch
│   │   │   ├── DiffLoader.swift        the files a commit changed, and their patches
│   │   │   ├── RepositoryWatcher.swift FSEvents
│   │   │   ├── CommitGraphUpkeep.swift decision 6
│   │   │   └── Snapshots.swift
│   │   ├── HistoryUI/                  AppKit
│   │   │   ├── CommitTableController.swift the table, and loading text for the rows in view
│   │   │   ├── CommitRowContent.swift  what a row shows
│   │   │   ├── CommitRowView.swift     drawing rows and their selection
│   │   │   ├── LaneRenderer.swift      drawing the graph in a row
│   │   │   └── CommitRowAccessibility.swift
│   │   ├── DiffUI/                     AppKit, TextKit 1
│   │   │   ├── DiffTextController.swift the text view and what's beside it, and handing documents over
│   │   │   ├── DiffTextView.swift      text that can be selected but not edited
│   │   │   ├── DiffLayoutManager.swift full-width line backgrounds, changed words and matches
│   │   │   ├── LineNumberGutter.swift  line numbers and the bars beside changed lines
│   │   │   ├── DiffTextBuilder.swift   attributed text, laid out ahead of time
│   │   │   └── ChangedWords.swift      which words of changed lines differ
│   │   ├── YagaUI/                     SwiftUI
│   │   │   ├── Workspace/              windows, finding git, the sidebar and the saved list of repositories
│   │   │   ├── Repository/             the repository model, panels, the refs panel, commit details
│   │   │   ├── Commands/               menus and keyboard shortcuts
│   │   │   ├── Settings/
│   │   │   └── Onboarding/             missing or outdated git
│   │   └── yaga-bench/                 benchmarks that use the real modules
│   └── Tests/
│       ├── GitCoreTests/
│       ├── GitRunnerTests/
│       ├── CommitGraphTests/
│       ├── RepositoryEngineTests/
│       ├── DiffUITests/                the text a patch shows, and handing documents between text views
│       ├── YagaUITests/                the list of repositories, the models windows keep, and selecting commits and files
│       ├── TestSupport/                the git the tests run, and the test repositories
│       └── Fixtures/                   scripts that build test repositories
├── Scripts/
│   ├── build-git.sh                builds an old git for CI
│   └── release.sh                  builds, signs and notarizes a release, and updates the appcast
├── .github/workflows/ci.yml
├── docs/
│   ├── decisions/
│   └── releasing.md
└── prototypes/                     throwaway experiments, never imported by the app
```

## Modules

| Module | What it owns | Depends on | Frameworks |
| --- | --- | --- | --- |
| `GitCore` | Object IDs, ref names, commit metadata, status entries and changed files, and a parser for every git output format yaga reads | nothing | Foundation |
| `GitRunner` | Finding git and checking its version, starting git, streaming its output, cancelling it, the long-running `cat-file` process, and the log of commands | `GitCore` | Foundation |
| `CommitGraph` | Reading commit-graph files and split chains through memory mapping, ordering history, and laying out graph lanes | `GitCore` | Foundation |
| `RepositoryEngine` | One session per repository: loading and caching history, refs, worktrees, status and diffs, watching the file system, keeping the commit-graph file current, and publishing snapshots | `GitCore`, `GitRunner`, `CommitGraph` | Foundation, CoreServices |
| `HistoryUI` | The commit list: the table, drawing rows and graph lanes, keyboard handling and accessibility | `GitCore`, `CommitGraph` | AppKit |
| `DiffUI` | The diff view: the TextKit 1 text view, line numbers, line backgrounds, and building attributed text | `GitCore` | AppKit |
| `YagaUI` | Windows, the sidebar, the refs panel, details, settings, menus and onboarding, and the main-actor models that connect sessions to views | all of the above | SwiftUI, AppKit |
| App target | The entry point, Sparkle, the Info.plist and assets | `YagaUI`, Sparkle | SwiftUI |
| `yaga-bench` | Benchmarks for the performance targets in the roadmap | `GitCore`, `GitRunner`, `CommitGraph`, `RepositoryEngine`, `HistoryUI`, `DiffUI` | AppKit |

These rules keep the layers apart:

- `GitCore`, `GitRunner`, `CommitGraph` and `RepositoryEngine` never import AppKit or SwiftUI. They can be tested and benchmarked without a window.
- Only `GitRunner` starts processes. Views never run git. They ask a session, and the session decides what to run.
- `HistoryUI` and `DiffUI` don't know about sessions. They take plain data and closures, so the benchmark tool can drive them with real data and no app around them.
- Sparkle is linked only into the app target.

<a id="windows-and-tabs"></a>

## Windows and the sidebar

Each window has a sidebar that lists repositories, each with its worktrees under it, and a selected worktree that the rest of the window shows (decision 13). A panel on the right lists the selected repository's branches, remotes, tags and stashes. The sidebar is the one macOS provides, so collapsing it and its saved width come from the system. The panel is a plain view of ours, because the inspector macOS provides animated by itself and made the window wider. The sidebar draws its own rows and its own button for hiding it, though, because a macOS sidebar list can't fill a row on hover or swap a row's label for its commands. So the sidebar handles the arrow keys and describes its rows to VoiceOver itself. The View menu's Hide Sidebar command, with Control-Command-S, is yaga's too. SwiftUI's own command collapses the sidebar without telling the window, which left the button and the menu each showing the wrong state. A worktree can also be opened in a window of its own, so that two agents' work can sit side by side.

The sidebar lists every repository the user has added, and every window lists the same ones (decision 14). `RepositoryList` holds them, opens a session for each one, and saves the list in Application Support whenever it changes. File > Open, or the row at the top of the sidebar, adds the repository that the chosen folder is in, unless it's listed already, and selects the worktree that the folder is in. git lists each repository's worktrees when the repository opens and whenever yaga becomes the active app, until yaga watches the file system. A window that shows a worktree that's gone moves to its repository's main worktree.

Each window keeps its selected worktree in the value that SwiftUI saves with the window, together with an ID of its own. Without the ID, opening a worktree in a new window would only bring forward the window that already shows it.

yaga turns off macOS window tabbing (`NSWindow.allowsAutomaticWindowTabbing = false`), because repositories are switched in the sidebar. [docs/main-window.md](docs/main-window.md) describes how the window looks. The sidebar needs to support:

- selecting a worktree, opening it in a new window or in Terminal, and adding, removing and reordering repositories
- moving between rows with the arrow keys, and Command-W closing the window
- VoiceOver, with each repository reported as a group that expands to show its worktrees
- each worktree's count of uncommitted files, and a mark on a repository when any of its worktrees has changes

A window keeps the models of the eight worktrees it showed most recently, with their history and the commit text it has read, so going back to one shows its history at once. Switching back to Linux takes no time instead of about a second. The model keeps the selected commit too, and the new commit list selects it and, once it has a height, scrolls only as far as it takes to show it, unless the window got there by way of a branch, which selects the branch's commit. The window builds a new commit list each time, though, so with nothing selected the list starts at the top again. Keeping the views too, with a container view controller that holds a child for each recently shown worktree and swaps which one is in the window, would also keep each worktree's scroll position.

The list of repositories doesn't depend on window restoration, which macOS skips after a normal quit unless the user turned off "Close windows when quitting an application". When macOS does restore windows, each one comes back with its worktree. Otherwise yaga opens one window, which shows the worktree selected last. With no repositories yet, it's the same window with an empty list and a button that opens one, so there's no separate welcome window to bring back.

When a launch comes with paths to open, AppKit treats it as a request to open files, and SwiftUI doesn't open its first window ([main window preview](prototypes/main-window/README.md)). yaga still has to handle those requests itself, both from Finder and from any command-line launcher such as `yaga .`.

## Commands

Every command is defined once, in `YagaUI/Commands`. A definition gives the command's name, its icon, its keyboard shortcut, when it's available, and what it does. The menu bar, the buttons in panel headers, context menus, the buttons that appear on hover in the sidebar and the refs panel, and a command palette if yaga gets one all show commands from those definitions instead of defining their own. That way a command has the same name and shortcut wherever it appears, and it's always in the menu bar. It also means the roadmap's requirement that every action has a keyboard shortcut can be checked in one place.

A command that isn't available is disabled in menus, and its buttons are disabled or hidden. Commands act on the selected worktree of the key window. Each window publishes its selected worktree through SwiftUI's focused values, and the menus read it from there.

Which commands each panel shows is decided as each feature is built, and [docs/main-window.md](docs/main-window.md) records where they go.

## Repository sessions

A repository is identified by its common git directory, the one `git rev-parse --git-common-dir` prints, resolved to a real path. All worktrees of a repository share one session, because they share objects, refs and the commit-graph file. The list of repositories in the sidebar is the registry that hands out sessions. It opens one for each repository and keeps it open while the repository is listed, because the sidebar shows how many uncommitted files each of its worktrees has, and windows that show the same repository share it. A session runs git in the git directory, except for commands about one worktree, such as listing refs with that worktree's `HEAD`, which run in the worktree's folder.

A session owns:

- one long-running `git cat-file --batch-command` process, shared by all of the repository's worktrees
- the mapped commit-graph files
- one FSEvents stream that covers the common git directory and every worktree
- its caches, such as the text of recently shown commits
- the background work that keeps the commit-graph file current (decision 6)
- a limit on how many git commands it runs at once, so that a burst of file changes can't start dozens of processes

A session publishes immutable snapshots, and the views read from those:

- a refs snapshot with branches, tags, remotes and `HEAD`
- a history snapshot with the order of the rows and the graph lanes for each row
- a worktree snapshot with every worktree, its branch, and the status of its files

Views don't receive commit text or diffs as part of a snapshot. They ask the session for them when they need them, for example when rows scroll into view or the user selects a file.

## How data flows

**Opening a repository.** yaga finds the repository's top level and common directory, gets a session from the registry, and then loads four things concurrently: refs with `git for-each-ref`, worktrees with `git worktree list --porcelain -z`, history, and the status of every worktree.

**History.** History starts from `HEAD` and every branch, remote branch and tag, which is what `git log HEAD --branches --remotes --tags` shows. The session lists the refs with `git for-each-ref`, and gets `HEAD` and what annotated tags lead to from `git show-ref -d`, which uses what git recorded when it packed the refs rather than reading the tags. While git lists them, the session maps the commit-graph file or chain and finds each of those commits in it. Commits newer than the files come from `git rev-list`, which stops where they meet the commits the files have, and they're added after the files' commits. `HistoryOrder` hands out rows the way git's own walk does, a few at a time, in topological order unless the user switches to date order (decision 12). The generation numbers in the file tell it how far below those rows it has to look, so the first screen is ready before most of history has been read.

git also counts down to its oldest starting point before it shows anything. With Linux's 952 tags, that's most of history, and git takes 1.2 seconds to print its first line. `HistoryOrder` waits until the walk reaches each starting point instead, and still gives git's order. On Linux, opening a session took about 15 ms, the first screen 36 ms more and its text 3 ms. Ordering the other 1.5 million rows and laying out their lanes took about a second, in the background.

From a cold disk cache, right after `sudo purge`, Linux's first screen with its text took about 124 ms, before lanes were added. Commits in the commit-graph file are sorted by ID, so even the first screen reads pages from all over the 90 MB file. Waiting for each page as the walk reached it took 0.4 seconds, so the session asks macOS to read the whole file ahead as soon as it's mapped, which takes about 20 ms. Most of the rest is git listing the refs, about 95 ms, during which it reads 27 MB from disk. Asking `for-each-ref` for what tags lead to made it read 955 objects from the pack, which took longer still.

**Lanes.** `LaneLayout` gives each row's commit a column, and the lines that join it to its parents. Each column holds a lane that waits for one commit, the next one down the line it draws. A commit takes the lane that waits for it, or the leftmost free column. Its lane then waits for its first parent, and each other parent gets the lane that already waits for it or a new one. Two lanes that would wait for the same commit join as soon as they meet, into the one on the left, and a lane steps left, one column a row, when the column next to it frees up. So lines only ever move left, and the main line stays in the first column unless it's cut.

Long lines are what make a large graph wide. Linux has about a hundred crossing a typical row, from merges whose other parents are far below. So `LaneLayout` cuts lines longer than 100 rows, the way gitk does: the line from the child ends in an arrow two rows below it, and the line to the parent starts with an arrow two rows above it, leaving the column free in between. With that, half of Linux's rows need 2 columns and 99% need 7 in topological order, or 4 and 12 in date order. Whether a line is cut depends on the rows below it, so a row is laid out once the 100 rows after it are in order, and the first screen orders twice as many rows. That's most of why it takes 36 ms rather than 28 ms. Laying out all of Linux takes about half a second in topological order and 0.7 seconds in date order.

Storing every line of every row would take too much memory, so the layout stores each row's column and the lines that change column or end at an arrow. Every 64 rows, it also stores which columns have a line crossing into the row. The commit list asks for the lines of the rows it draws, and the layout works out the straight ones from the nearest of those.

The graph is as wide as the rows in view need, up to 10 columns. While the user scrolls, it only widens, so the text doesn't move back and forth, and once scrolling stops it fits the rows in view again. Each column has a color, and the first, where the main line usually runs, has the accent color.

git doesn't use the commit-graph files in a shallow clone, when replace refs or grafts change commits' parents, or when `core.commitGraph` is false, and neither does yaga. yaga also skips files it can't read, as git does. Then, and when there's no file yet, `git rev-list` lists every commit with its parents and date. That's slow in a large repository, and without generation numbers all of history is counted before the first row. On Linux, the first screen took about 21 seconds that way instead of 35 ms, and `git rev-list` was about 12 of those. So yaga writes the file in the background (decisions 5 and 6).

**Keeping the commit-graph file current.** Each time a window shows a worktree or loads its history again, the session checks whether the files have every commit that branches, remote branches and tags lead to, and runs `git commit-graph write --reachable --split` if they don't. It runs apart from loading history, so the file still gets written when the user moves on before history has loaded, and only one update runs at a time. `--reachable` follows refs, so what only a detached `HEAD` reaches never gets into the file, and yaga doesn't write for those commits. git adds changed-path filters only to files that already have them, so yaga doesn't add them and doesn't take away a user's.

Updates run at macOS's background priority, which `posix_spawn` sets for each process. On Linux, the first write took about 82 seconds that way, instead of 18 at normal priority. Adding one new commit took 0.25 seconds, and finding nothing to write took 0.16. History on screen stays as it is when a write finishes. It already has every commit, and loading it again would only change how quickly it loads, so the next load is the one that reads the file. While the file is missing, the history panel says why history is slow and what yaga is doing about it, in repositories with at least 50,000 commits. A setting turns all of this off.

The commit list asks for the text of the rows it's about to draw, and of a screen above and below them, in one batch. The repository's model keeps the text it has, and the session reads the rest with `cat-file`.

**Selecting a commit.** The selection is a commit rather than a row, so it stays selected when history loads again in another order. The model finds its new row in each history that arrives. While only the first rows have loaded the commit may not be among them, and it stays selected until the rest arrive. Once history is complete, a commit that isn't in it is no longer selected. The commit list reports only what the user selects, so that reloading the list can't change the selection.

The commit panel gets the commit's message from `cat-file`, and then its files from `git diff-tree --raw --numstat -z -M`, which runs in the git directory because a commit doesn't belong to a worktree. A commit without parents adds all of its files, and a merge is compared with its first parent, which shows what it brought into the branch. Selecting another commit cancels the load, which stops git. The previous commit's files stay until the new ones arrive, because a list that emptied on every step through history would flash. After 150 ms the panel shows a spinner instead. In a partial clone, listing files makes git download what it's missing, as `git show` does.

On a Release build, a commit that changes one file showed its files about 30 ms after being selected, most of it starting git. A generated commit that changes 20,000 files took about 450 ms, nearly all of it git counting lines, and git took about 75 ms to list those files without counting. Going through those commits and scrolling their lists, the main thread never stalled for more than about 30 ms, which is two frames at 60 Hz but not at 120 Hz. That was measured in an off-screen window. Only the rows of the file list are in a lazy stack, because they're all the same height, so it knows how tall it is. With the commit's message in the stack too, it guessed too tall, and jumping to the end of the list left the panel blank.

**Checking out a branch.** Double-clicking a branch's badge in history runs `git switch --end-of-options <branch>` in the worktree's folder, because a ref can be named like an option. A remote branch goes through the local branch of the same name, and when that doesn't exist yet, `git switch --create=<branch> --track refs/remotes/<remote>/<branch>` makes it. The name comes from the configured remotes, because `--track` alone takes everything after the first slash, which is wrong for a remote with a slash in its name. When another worktree has the branch checked out, the session says which one rather than running git. git refuses to overwrite uncommitted changes, so yaga doesn't ask first, and shows what git said when it refuses. This is the one command that changes the worktree's files, so unlike background reads it takes optional locks, and it runs in a task that no view can cancel, since stopping git could leave files half written. Afterward the model looks at the worktree as it does when yaga becomes active, and the repository list reads the worktrees again for the sidebar and the title row.

**Uncommitted changes.** `git status --porcelain=v2 -z` says which files have changes, and it runs in the worktree's folder, because each worktree has its own index and files. While there are any, the model adds a row before the first commit (decision 15). Selecting the row lists the files again with their line counts, which come from `git diff-index --cached --numstat` and `git diff-files --numstat`. `git diff-files` also lists a file that was only touched, because yaga never writes the index, so those lists only add counts to what status listed. Patches come from the same two commands with `-p`, from `git diff-index` against `HEAD` for a conflicted file, and from `git diff --no-index` against `/dev/null` for an untracked one. A test checks that the index stays exactly as it was. In a repository without commits, the staged files compare with the empty tree.

Status never downloads anything, because it runs for every worktree in the sidebar without anyone asking. In a partial clone with no files checked out, like a clone of Linux for measuring history, git would otherwise fetch every tree in `HEAD`, so yaga would download them just by opening. `GIT_NO_LAZY_FETCH` makes git fail instead, and that worktree has no row or count. Selecting a file can still download what it needs, as selecting a commit does, because someone asked for it.

The line from the row to `HEAD` is drawn over the graph's layout, and the row's number is added to every row below it at one place in the model, so the graph doesn't change when the row comes and goes. For now, yaga looks again when it becomes the active app, when a window shows the worktree again, and on View > Reload, and it loads history again if a ref moved. A selected file is read again too. If its patch is the same, nothing changes on screen, and otherwise the new text stays at the same place. The sidebar counts each worktree's files the same way, one worktree at a time and at low priority, and a window's newer count for its own worktree replaces the list's. That means two `git status` commands for the window's worktree when yaga becomes active, until live refresh replaces all of this.

`yaga-bench status` measures this. On an M1 Max, on a generated worktree with about as many files and folders as Linux (88,000 and 6,000), the count took about 370 ms, against the roadmap's target of 300 ms. git took about 330 ms of that, and about 230 ms of git's time goes on looking for untracked files, whether it lists folders or every file. `git config` takes 14 ms and the rest is starting processes. The prototype measured 251 ms for the same command on a real checkout of Linux, so a real one may just make the target, but it hasn't been measured with yaga. git's untracked cache made it about two and a half times faster in the prototype. The roadmap leaves whether to use it to release 2, and it needs writing to the index once. Listing the files with line counts took about 410 ms with 15 files changed.

**The refs panel.** `RefDetailsLoader` reads what the panel lists, when the panel shows, when yaga becomes active and on View > Reload, and the lists on screen stay until the new ones arrive. A hidden panel reads nothing. One `git for-each-ref refs/heads/` gives each branch's date, its upstream and how far it is from that, and how far it is from the main branch, which `%(ahead-behind:)` counts all at once. Another for `refs/remotes/` and `refs/tags/` gives their dates and what each tag points to. `git config` gives the remotes' URLs, and yaga only keeps the host and path, so a token in a URL is never on screen. `git rev-list --walk-reflogs` gives the stashes, and it ignores settings such as `log.showSignature`. The session's `cat-file` then reads the subject of each tag's commit, a thousand at a time, so that the commit list can read its rows in between.

The panel reads refs without anyone asking for a download, so these commands set `GIT_NO_LAZY_FETCH`, as status does, and they only ask about the objects that refs point to, which a partial clone always has. That's why it asks what type of object a tag points to rather than for `%(*subject)`, which would make git fetch the tree that Linux's oldest tag points to. And it runs `%(ahead-behind:)` only on branches, because that follows tags too.

`yaga-bench refs` measures this. On an M1 Max with a release build, Linux's 952 tags took about 60 ms to read, and a generated repository with 500 branches, 5,000 remote branches and 20,000 tags took about 1.8 seconds, none of it on the main thread. Sorting happens on the main thread, once for each list that arrives and each change of order.

The panel gives way when the window gets too narrow (decision 13), and that depends only on the width of the column it shares with the middle, which showing the panel doesn't change. Its commands are a single item in the window's toolbar, as wide as the panel less a margin measured on macOS 27, which keeps the button that hides the panel at the panel's edge. The item comes after the button that hides the panel because SwiftUI puts a view's toolbar items after those of the views around it, and that's also why history's commands are declared by the window rather than by the history panel.

macOS keeps the middle at least as wide as the sidebar, and it clips the columns rather than widening the window. So a sidebar wider than half the window is clipped whether the panel shows or not. A resize too fast for a layout in between, as when a window is snapped to a narrower size, can make AppKit collapse the sidebar itself, and then the panel fits and stays.

**Changes on disk.** FSEvents reports changed paths, and the session sorts them by what they affect:

- refs, `packed-refs` and `reftable/` affect refs and history
- `HEAD` affects the current branch
- the index and files in a worktree affect that worktree's status
- `objects/info/commit-graph*` means the commit-graph file needs to be mapped again

The session waits about 100 ms for related changes to arrive together, reloads only what changed, and publishes a new snapshot. On the main actor, yaga applies the difference: new commits are inserted at the top of the table, and badges and status update in place.

**Diffs.** The commit panel's list of changed files comes from `git diff-tree --raw --numstat -z -M`. Selecting a commit selects its first file, and the diff panel shows that file's patch, which comes from `git diff-tree -p -M` limited to the file. For a renamed file it's limited to both paths, because git finds a rename only when it sees both sides, and the file would otherwise look new. `GIT_LITERAL_PATHSPECS` makes git read the paths as names, since a name can hold a `*`. `diff-tree` doesn't read `diff.noprefix`, `diff.context` or `diff.algorithm`, so the user's settings don't change what yaga shows.

The list already says when a file has no lines to compare, such as a binary file or one whose mode is all that changed, so yaga doesn't run git for those and says what changed instead. git stops when a patch passes 64 MB, because a file like a data dump could take gigabytes, and the panel says the patch is too large. All 12,914 files that a release of Linux changes come to 45 MB.

As with commits, what's showing stays until the next file's patch is ready, and after 150 ms the panel shows a spinner. Selecting another file or commit cancels the load, which stops git. The patience timers are separate tasks that stop at the same moment, because a cancelled load can take a while to finish, and the next file may already be showing when its timer would go off.

**The diff's text.** `PatchParser` keeps the hunks and skips the lines that describe the file, which yaga knows already. `DiffTextBuilder` makes the text and lays all of it out on a background task, which TextKit allows while no view is attached, and the text view only has to draw it. That has two results. The main thread never waits for layout. And the text view knows the exact height, where non-contiguous layout would estimate it, 30% short on a long patch, and the scroller would drift as the estimate changed. Layout takes about 15 microseconds a line, so a patch over 50,000 lines isn't laid out ahead of time. It shows at once with an estimated height, and lays out as it's looked at. The longest patch of a file in a Linux release has 40,325 lines.

Each line of a patch is one row, which the rest of the diff view relies on. Every row has the same height, whatever fonts its characters fall back on, and nothing wraps. Control characters and the characters that end a line show as symbols. A form feed, which old C code has, would otherwise end the text container. A carriage return at the end of a line stays, because with the newline after it, it still ends one row, and it's there when the text is copied. A line that isn't valid UTF-8 is read as Latin-1, and a line over 10,000 bytes is cut off and says so. Drawing takes time for all of a line, even the part out of view, so a window of lines a megabyte long took between 0.2 and 1 second to draw each time the text moved.

The line numbers and the bars beside changed lines are in a view beside the scroll view, so that a selection copies only the code. An added line's bar is solid and a removed line's is striped, so that they differ without relying on color. They aren't in the scroll view's ruler, because AppKit lays out the text under a ruler on the macOS this was built with. Two more things about TextKit 1 took finding out, and `DiffTextController` has them in comments:

- A text view made with `init(frame:)` uses TextKit 2, and believes it owns its text system, so it takes the text with it when it goes away. `init(frame:textContainer:)` does neither. This matters because a document outlives its view when a window goes to another worktree and back.
- Most of a text view's settings, such as whether it can be edited, are kept with its layout manager, and each document has its own. So they're set again for each document.

**Changed words.** `ChangedWords` runs as part of `DiffTextBuilder`, away from the main thread, and `DiffLayoutManager` fills behind the words it finds, in the lines it's drawing. It compares each run of removed and added lines as a whole, with Myers' algorithm for the shortest edit, rather than pairing lines up. That means nothing has to guess which added line came from which removed line, and a word that a reflowed comment moves to the next line doesn't count as changed. It compares words and punctuation marks, not spaces, because spaces match as readily as words do, and a run of unrelated lines would break into scraps. Spaces count as changed only between words that are the same on both sides and at the start or end of a line that matches, and then only the part that differs, so a line indented further marks only the extra. A line where less than 30% stays the same shows no marks, because it was replaced, and its background already says that.

A run with more than 1,000 differences shows no marks, because the time and memory for one run grow with the square of the differences. So does a patch over 50,000 lines, which isn't laid out ahead of time either. On a Release build, with 40,368 generated lines, finding the words took 30 ms when each changed line had one changed word. The longest it took in any patch tried was 0.8 seconds, with runs of 65 removed lines and 65 added lines that had nothing in common, on top of the 0.65 seconds for the rest. Eight marks on every changed line took 0.56 seconds to find, and didn't take scrolling past 10 ms.

**Finding text in the diff.** Decision 9 counted the find bar among the things AppKit provides, and yaga used it at first. It's drawn by macOS and sits on top of the text, so it couldn't become the same box in the panel's header that the refs panel has. Now `SelectedFile` looks for the text with `NSString`'s search on a background task, which each key press cancels, and `DiffLayoutManager` fills behind the matches in the lines it's drawing, so the number of matches doesn't affect drawing. The marks and the count stay until the new search is done, so they don't flash while someone types. Matches belong to a document, and the text view ignores any from the document before the one it's showing. On a Release build, searching 40,000 lines took 20 to 60 ms, and 400,000 lines took 0.2 to 0.6 seconds, the longest being a letter with 2 million matches.

On a Release build, a small file's patch showed about 25 ms after being selected, and a patch of 44,005 lines took about 620 ms, nearly all of it layout. While they loaded, the main thread didn't stall for more than 11 ms, and usually about 4 ms, measured in an off-screen window. `yaga-bench diff` times each step from moving the text until the window has drawn. With 40,368 generated lines, no step of scrolling or jump took longer than 11 ms, which is within one frame at 60 Hz and within two at 120 Hz. With 400,000 lines, which have an estimated height, one jump took 170 ms and scrolling stayed under 11 ms.

## Concurrency

- yaga uses the Swift 6 language mode with complete concurrency checking.
- Every target also turns on the upcoming features that Xcode calls approachable concurrency. With them, a nonisolated async function runs on its caller's actor unless it's marked `@concurrent`, so moving work off an actor is always written down.
- `YagaUI`, `HistoryUI`, `DiffUI` and the app target make the main actor their default isolation, with SwiftPM's `defaultIsolation(MainActor.self)` setting and Xcode's `SWIFT_DEFAULT_ACTOR_ISOLATION`. The window tabs preview used that setting. The engine modules keep the normal default, where code isn't isolated unless it says so.
- Each repository session is an actor. Work that takes real time, such as ordering history or building attributed text, runs in `@concurrent` functions, away from both the session and the main actor.
- Blocking calls never run on Swift's shared thread pool. That pool has about one thread per CPU core, and a thread stuck in a blocking `read` stalls unrelated work. Pipes are read with `DispatchIO`, and process exit is detected with a dispatch source before `waitpid` collects the status.
- Output is read a chunk at a time, as the code that uses it asks for more. When that code falls behind, git waits on a full pipe, so even the output of `git log` for all of Linux never piles up in memory.
- Every git command belongs to a task. Cancelling the task stops the process, first with `SIGTERM` and then with `SIGKILL` if it hasn't exited two seconds later. Leaving a loop over streamed output early stops it the same way. Each git leads a process group of its own, and the signals go to the whole group, so anything git started stops too. Selecting a different commit cancels the diff that was loading for the previous one.
- Data crosses between actors as `Sendable` values. History is stored as parallel arrays, one array for each field, rather than as an object for each commit, and the arrays are copy-on-write, so passing a snapshot along doesn't copy it.
- Every load carries a generation number, and the session drops results from a generation that's already been replaced.

## Rules for talking to git

- **Every git command goes through `GitRunner`** and is recorded in the command log, with its arguments, how long it took, and its exit status. A view of that log comes later, and it's how yaga keeps the vision's promise to show what Git is doing.
- **yaga only parses output meant for machines:** `-z`, `--porcelain=v2`, `--format` with NUL separators, and `cat-file --batch-command`. It never parses text meant for people.
- **Background reads pass `--no-optional-locks`,** so yaga never holds the index lock while the user or an agent is running git.
- **yaga leaves the user's git configuration alone.** A command overrides only the settings that change the shape of its output. A patch, for example, is read with `--no-color` and `--no-ext-diff`, so that colors and external diff tools never reach the parser. The pager needs nothing, because git only starts one when its output is a terminal.
- **The environment is the user's, with three changes.** yaga sets `PATH` to the one from the user's login shell, and `GIT_TERMINAL_PROMPT=0` so that git never waits for input nobody can see. It also clears the variables that choose a repository, the ones that `git rev-parse --local-env-vars` lists, such as `GIT_DIR`. Otherwise a variable inherited from wherever yaga was started, such as a git hook, could point every command at the wrong repository.
- **Refs always come from git** (`for-each-ref` and `show-ref`), never from reading files under `.git`. Git 3.0, expected in spring 2027, makes the reftable format the default for new repositories, and reftable stores refs in a different way.
- **Object IDs can be SHA-1 or SHA-256.** Git 3.0 makes SHA-256 the default for new repositories. A session learns the hash from `git rev-parse --show-object-format`. `ObjectID` holds up to 32 bytes, and the commit-graph reader handles both hash versions.
- **History rows refer to commits by their position in the commit-graph file,** a 32-bit number, rather than by object ID. Object IDs are read from the mapped file when they're needed. For 1.5 million commits that's 6 MB of positions instead of 48 MB of SHA-256 IDs. Commits newer than the file get positions after the file's last one.

## Finding git

At launch, `GitInstallation` looks for git in this order:

1. the path set in Settings, if there is one. yaga uses that git or explains what's wrong with it, and never falls back to another one.
2. the folders in the `PATH` from the user's login shell, because apps started from Finder get a minimal `PATH` (decision 3). yaga starts the shell the way a terminal does, as an interactive login shell, since many people set `PATH` in files that only those read, such as `.zshrc`. It gives the shell five seconds.
3. Homebrew's locations, `/opt/homebrew/bin` and `/usr/local/bin`
4. `/usr/bin/git`

yaga runs `git version` for each git it finds and uses the first one that's 2.44 or later (decision 8). An older git is passed over rather than ending the search. A Mac often has an old git first on the `PATH` and a newer one elsewhere, and decision 8 only asks people to upgrade when their only git is too old. Settings shows which git yaga uses, its version, and the gits it passed over. When no git is new enough, yaga explains what to do instead of opening repositories.

Wherever `/usr/bin/git` comes up in the search, yaga runs it only if `xcode-select -p` finds the developer tools, because otherwise running it opens the dialog that offers to install them. yaga recognizes that git by its real path, so a folder in the `PATH` that leads to it through a symbolic link is caught too.

## Testing

- Unit tests use Swift Testing.
- Parsers are tested against captured git output stored as files, captured from both git 2.44 and the newest release.
- Test repositories are built by the scripts in `Tests/Fixtures` when the tests run, with fixed names and dates so that object IDs are the same on every run and with every git version. The scripts and the tests keep the user's and the system's git configuration out with `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`, so that settings such as commit signing can't change the results.
- The `TestSupport` target builds each test repository once per test run, and finds the git the tests use, which is the first supported git on the `PATH`. CI puts the git it's testing first.
- There are three so far. `basic` is a small repository. `changes` has commits that change files in every way a commit can: adding, deleting, renaming, changing a mode or a file's kind, binary files, a merge and an empty commit. `history` builds one history five times, with its commit-graph stored as a single file, as a split chain, as a chain whose upper layers have no corrected commit dates, as a file that leaves out the newest commits, and in a SHA-256 repository. The history has merges, an octopus merge, a second root, commits with the same time on several branches, and dates out of order. Later repositories will cover reftable repositories.
- Engine tests run real git against those repositories. The commit-graph tests compare every commit's parents, dates and generation numbers, and the order of history from several sets of tips, with what git prints. The lane tests follow every line down from each commit's dot, and check that it reaches the commit's parents, through arrows when it's cut. The session tests compare the history a session loads with `git log`, in every repository and also in copies the tests change: a shallow one, one with replace refs, one with a damaged commit-graph file, one with `core.commitGraph` set to false, a bare clone, one with a detached `HEAD`, and ones with linked worktrees, including one whose folder was removed. The upkeep tests write commit-graph files in copies of the test repositories, and check that history then reads them and still matches `git log`. They also cover each reason to skip a repository, a lock another git holds, damaged files, and closing the session during a write.
- The YagaUI tests check the saved list of repositories against real git: adding a repository twice, adding one from a linked worktree, a folder outside any repository, removing one, one that moved, one that's gone, worktrees that were added or removed, and a file that can't be read. They also check the models a window keeps, when those load history again, when they update the commit-graph file or say why they won't, and how a selected commit follows history as it loads. The commit list's tests check that it reports only what the user selects.
- The uncommitted changes tests run real git against small repositories that each test makes: every kind of change, a file both staged and unstaged, renames, untracked, binary and empty files, a conflict, a repository without commits, SHA-256, a file that was only touched, the setting that turns off untracked files, and settings that would change a patch or run a command. The model's tests check how the row and the selection move as files come and go.
- The refs panel tests run real git against small repositories that each test makes: a branch compared with its upstream, the main branch and an upstream that's gone, which worktree has each branch, remotes with credentials in their URLs and remotes that are gone, every kind of tag, stashes, a repository without commits, a bare repository, and a partial clone that must download nothing.
- CI runs everything against git 2.44 and the newest git.
- `yaga-bench history` measures the first screen of history and ordering and laying out the rest, first from `HEAD` with the reader alone, then through a session from every ref, as the app loads it, and reports how wide the graph's rows are. `--verify` compares both orders with `git log`. `--cold`, run right after `sudo purge`, loads history once and reports how many pages each step read from disk, and `--parts` takes the steps one at a time instead of the way the app overlaps them. A clone of Linux with only its commits is enough for it. `yaga-bench commit-graph` times bringing a repository's commit-graph files up to date, and writes to the repository, so it takes a copy. A CI job that runs it on a cached clone, and fails when a performance target from the roadmap is missed, is still to be added.

## Building and releasing

The project and CI use Xcode 27.2, because of the JSON project format. CI runs on GitHub's `xcode-27` runner image. For now it runs only when started by hand, from the Actions tab or with `gh workflow run ci.yml`, to save macOS runner minutes. It builds and tests YagaKit twice, once with git 2.44.0, which `Scripts/build-git.sh` builds from source and CI caches, and once with the git that comes with the image. It also builds the app.

The app's bundle identifier is `build.yaga.app`, and the app is named yaga. It isn't sandboxed, and the hardened runtime that notarization requires is turned on by a build setting, so the app needs no entitlements file. Development builds are signed to run locally and don't need a developer account.

`Scripts/release.sh` archives the app, signs it with a Developer ID, notarizes and staples it, zips it, and adds it to the Sparkle appcast (decision 1). The zips are published as GitHub releases, and the appcast at `https://yaga.build/appcast.xml`. [docs/releasing.md](docs/releasing.md) describes the one-time setup and the steps for each release. Sparkle starts only when the Info.plist has the public key that updates are signed with, so development builds never look for updates.

## Still open

- What a session does while none of its worktrees is showing. Every repository in the sidebar keeps a session open (decision 14), so this matters as soon as someone lists a few. A session could close its `cat-file` process and watch only enough to keep the sidebar's counts of uncommitted files current.
- Whether a window keeps each worktree's commit list as well as its history, so that switching back keeps the scroll position.
- Whether the commit panel shows a very large commit's files before git has counted their lines. git can list 20,000 files in about 75 ms, and counting their lines takes about 450 ms.
- Whether a merge can be compared with its other parents, or show only what its conflict resolutions changed.
- Whether a patch should follow the user's `diff.algorithm` and `diff.context`, as `git diff` in their terminal does. Going by `git show` would, and it also brings in settings that change the output's shape, such as `log.showSignature`.
- How VoiceOver tells added lines from removed ones in the diff. The bars aren't in the text, so it reads only the code.
- Which editor opening a file should use. Opening a file with its default app could run it, as a `.command` file does, so this needs a setting rather than `NSWorkspace.open`.
- Whether a very long patch should wait to be laid out, for the exact height. A patch of 400,000 lines would take six seconds.
- Whether yaga runs the git that `/usr/bin/git` stands for directly. That stub looks up the developer tools every time it runs, which made a short command take 13 ms instead of 6.4 ms.
- Whether yaga saves the login shell's `PATH` between launches, so that finding git doesn't wait for the user's shell to start.
- Whether clicking an arrow on a cut line jumps to the commit at its other end, and whether the lanes' colors should follow branches rather than columns.
- How much commit text yaga keeps. For now the repository's model keeps up to 20,000 commits. It could depend on the size of the repository, or move into the session so that windows showing the same repository share it.
- The open questions about the layout, which the [main window](docs/main-window.md#still-open) lists.
- Whether a command palette ships in release 1.
- Reading commit-graph layers from alternate object folders. git looks for a chain's layers there, and yaga doesn't yet.
- What Command-1 to Command-9 do now that there are no tabs.
- Whether git 2.44 knows `GIT_NO_LAZY_FETCH`. A git that doesn't would ignore it, and status would download what it's missing in a partial clone. The test for it only runs on git 2.45 and newer, because that hasn't been checked on 2.44.
- Whether listing a worktree's uncommitted files meets the 300 ms target on a real checkout of Linux, and whether yaga should use git's untracked cache if not.
- Whether sorting the refs panel's lists should move off the main thread. It takes a moment only with tens of thousands of refs.
- Whether yaga should stop reading `status.showUntrackedFiles` before every `git status`, for example by remembering it for a while. It takes 14 ms each time.
