# Architecture

This document describes how yaga is put together: how the code is organized, which module owns what, how data moves from git to the screen, and the rules that keep the app fast. It builds on the [decisions](docs/decisions/README.md), which explain why each choice was made, and on what the [prototypes](prototypes/) measured. When the code and this document disagree, one of them needs fixing.

## The shape of the app

yaga is a Swift app for macOS 26 and later (decision 2). It runs the user's own git (decisions 3 and 8) and reads git's commit-graph file directly to order history (decisions 5 and 6). The window is SwiftUI, except for the two views that have to handle very large amounts of data: the commit list is an AppKit `NSTableView` (decision 7), and the diff is a TextKit 1 `NSTextView` (decision 9).

A window holds tabs that yaga draws itself, one tab for each open repository, and there can be several windows (decision 10). Each repository has one session, which owns everything yaga knows about it, such as its git processes, its file watcher and its caches. Sessions don't depend on windows or tabs, so two tabs that show the same repository share one session.

From the bottom up, the code is in these layers:

1. **Git itself.** This layer covers the object IDs, refs, commits, status entries and diffs that yaga works with, and parsers for the git output that describes them.
2. **Running git and reading its files.** One module starts git processes, and another reads commit-graph files and lays out history.
3. **Repository sessions.** This layer loads and caches what each repository contains, watches it for changes, and publishes snapshots.
4. **Views.** The commit list and the diff view are AppKit. The window, tabs, navigator, details and settings are SwiftUI.
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
│   │   │   ├── Refs.swift
│   │   │   ├── CommitInfo.swift
│   │   │   ├── StatusEntry.swift
│   │   │   ├── DiffFile.swift
│   │   │   └── Parsing/                one parser per git output format
│   │   │       ├── CommitParser.swift      commit objects from cat-file
│   │   │       ├── RefListParser.swift     for-each-ref
│   │   │       ├── WorktreeListParser.swift
│   │   │       ├── StatusParser.swift      status --porcelain=v2 -z
│   │   │       ├── RawDiffParser.swift     diff --raw -z
│   │   │       └── PatchParser.swift       unified patches
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
│   │   │   ├── CommitGraphFile.swift   one mapped commit-graph file
│   │   │   ├── CommitGraphChain.swift  split chains
│   │   │   ├── HistoryOrder.swift      date order and topological order
│   │   │   └── LaneLayout.swift        graph lines for each row
│   │   ├── RepositoryEngine/
│   │   │   ├── RepositorySession.swift one actor per repository
│   │   │   ├── SessionRegistry.swift
│   │   │   ├── HistoryLoader.swift     commit-graph, newer commits, fallbacks
│   │   │   ├── CommitTextCache.swift
│   │   │   ├── RefsLoader.swift
│   │   │   ├── WorktreeLoader.swift
│   │   │   ├── StatusLoader.swift
│   │   │   ├── DiffLoader.swift
│   │   │   ├── RepositoryWatcher.swift FSEvents
│   │   │   ├── CommitGraphUpkeep.swift decision 6
│   │   │   └── Snapshots.swift
│   │   ├── HistoryUI/                  AppKit
│   │   │   ├── CommitTableController.swift
│   │   │   ├── CommitRowView.swift
│   │   │   ├── LaneRenderer.swift
│   │   │   └── CommitRowAccessibility.swift
│   │   ├── DiffUI/                     AppKit, TextKit 1
│   │   │   ├── DiffTextView.swift
│   │   │   ├── DiffLayoutManager.swift full-width line backgrounds
│   │   │   ├── LineNumberRuler.swift
│   │   │   └── DiffTextBuilder.swift   attributed text and changed-word highlights
│   │   ├── YagaUI/                     SwiftUI
│   │   │   ├── Workspace/              windows, the tab strip, the tab container
│   │   │   ├── Repository/             panels, the navigator, commit details
│   │   │   ├── Commands/               menus and keyboard shortcuts
│   │   │   ├── Settings/
│   │   │   └── Onboarding/             missing or outdated git
│   │   └── yaga-bench/                 benchmarks that use the real modules
│   └── Tests/
│       ├── GitCoreTests/
│       ├── GitRunnerTests/
│       ├── CommitGraphTests/
│       ├── RepositoryEngineTests/
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
| `YagaUI` | Windows, tabs, the navigator, details, settings, menus and onboarding, and the main-actor models that connect sessions to views | all of the above | SwiftUI, AppKit |
| App target | The entry point, Sparkle, the Info.plist and assets | `YagaUI`, Sparkle | SwiftUI |
| `yaga-bench` | Benchmarks for the performance targets in the roadmap | `RepositoryEngine`, `HistoryUI`, `DiffUI` | AppKit |

These rules keep the layers apart:

- `GitCore`, `GitRunner`, `CommitGraph` and `RepositoryEngine` never import AppKit or SwiftUI. They can be tested and benchmarked without a window.
- Only `GitRunner` starts processes. Views never run git. They ask a session, and the session decides what to run.
- `HistoryUI` and `DiffUI` don't know about sessions. They take plain data and closures, so the benchmark tool can drive them with real data and no app around them.
- Sparkle is linked only into the app target.

## Windows and tabs

Each window has an ordered list of tabs and a selected tab. A tab shows one repository. Inside the tab, the navigator lists the repository's worktrees, and choosing one changes what the tab shows. A worktree can also be opened in a tab of its own, so that two agents' work can sit in two tabs.

yaga turns off macOS window tabbing (`NSWindow.allowsAutomaticWindowTabbing = false`) and draws its own tab strip. [docs/main-window.md](docs/main-window.md) describes how the window and its tabs look. The tabs need to support:

- selecting, closing and reordering tabs, and moving a tab to a new window
- keyboard shortcuts: Control-Tab and Control-Shift-Tab, Command-1 to Command-9, Command-T for a new tab, and Command-W to close the tab rather than the window
- VoiceOver, with the tab strip reported as a tab group and each tab offering a press action that selects it
- a small status mark on a tab, for example when a worktree has uncommitted changes

The window keeps the views of hidden tabs alive. A container view controller holds one child view controller per tab and swaps which one is in the window, so a hidden tab keeps its scroll position and selection, draws nothing, and comes back instantly.

Each window saves its list of tabs, with the repository and selected worktree for each, and restores them when yaga relaunches. When yaga launches with nothing to restore, it opens a window that shows recent repositories. The previews showed that launching needs to be designed on purpose:

- SwiftUI doesn't reopen a single welcome window that was closed at the last quit ([window tabs preview](prototypes/window-tabs/README.md)).
- When a launch comes with paths to open, AppKit treats it as a request to open files, and SwiftUI doesn't open its first window ([main window preview](prototypes/main-window/README.md)). yaga has to handle open requests itself, both from Finder and from any command-line launcher such as `yaga .`.

## Commands

Every command is defined once, in `YagaUI/Commands`. A definition gives the command's name, its icon, its keyboard shortcut, when it's available, and what it does. The menu bar, the buttons in panel headers, context menus, the buttons that appear on hover in the navigator, and a command palette if yaga gets one all show commands from those definitions instead of defining their own. That way a command has the same name and shortcut wherever it appears, and it's always in the menu bar. It also means the roadmap's requirement that every action has a keyboard shortcut can be checked in one place.

A command that isn't available is disabled in menus, and its buttons are disabled or hidden. Commands act on the selected tab of the key window. Each window publishes its selected tab through SwiftUI's focused values, and the menus read it from there.

Which commands each panel shows is decided as each feature is built, and [docs/main-window.md](docs/main-window.md) records where they go.

## Repository sessions

A repository is identified by its common git directory, the one `git rev-parse --git-common-dir` prints, resolved to a real path. All worktrees of a repository share one session, because they share objects, refs and the commit-graph file. A registry hands out sessions, and a session closes when the last tab that shows it closes.

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

**History.** The session maps the commit-graph file or chain and finds the position of each branch tip in it. Commits newer than the file come from `git rev-list`. Ordering the whole history and laying out its lanes run in the background, which took 372 ms for Linux in the prototype. When git wouldn't use a commit-graph file, or there isn't one yet, the session streams `git log` instead and adds graph lines once the file exists (decisions 5 and 6). The commit list asks for the text of the rows it's about to draw, in batches, and the session answers from its cache or from `cat-file`.

**Changes on disk.** FSEvents reports changed paths, and the session sorts them by what they affect:

- refs, `packed-refs` and `reftable/` affect refs and history
- `HEAD` affects the current branch
- the index and files in a worktree affect that worktree's status
- `objects/info/commit-graph*` means the commit-graph file needs to be mapped again

The session waits about 100 ms for related changes to arrive together, reloads only what changed, and publishes a new snapshot. On the main actor, yaga applies the difference: new commits are inserted at the top of the table, and badges and status update in place.

**Diffs.** The list of changed files comes from `git diff --raw -z -M` (or `git diff-tree` for a single commit). The patch for the selected files is loaded on demand and parsed in the background. `DiffTextBuilder` builds the attributed text off the main actor, and only setting it on the text view happens on the main actor.

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
- **Refs always come from git** (`for-each-ref`), never from reading files under `.git`. Git 3.0, expected in spring 2027, makes the reftable format the default for new repositories, and reftable stores refs in a different way.
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
- So far there's a small `basic` repository. Later ones will cover:
  - merges and octopus merges
  - renames
  - worktrees
  - split commit-graph chains
  - shallow clones and replace refs
  - SHA-256 and reftable repositories
- Engine tests run real git against those repositories.
- CI runs everything against git 2.44 and the newest git. A separate job will run `yaga-bench` on a cached Linux clone and fail when a performance target from the roadmap is missed. That job comes with the first benchmark.

## Building and releasing

The project and CI use Xcode 27.2, because of the JSON project format. CI runs on GitHub's `xcode-27` runner image. For now it runs only when started by hand, from the Actions tab or with `gh workflow run ci.yml`, to save macOS runner minutes. It builds and tests YagaKit twice, once with git 2.44.0, which `Scripts/build-git.sh` builds from source and CI caches, and once with the git that comes with the image. It also builds the app.

The app's bundle identifier is `build.yaga.app`, and the app is named yaga. It isn't sandboxed, and the hardened runtime that notarization requires is turned on by a build setting, so the app needs no entitlements file. Development builds are signed to run locally and don't need a developer account.

`Scripts/release.sh` archives the app, signs it with a Developer ID, notarizes and staples it, zips it, and adds it to the Sparkle appcast (decision 1). The zips are published as GitHub releases, and the appcast at `https://yaga.build/appcast.xml`. [docs/releasing.md](docs/releasing.md) describes the one-time setup and the steps for each release. Sparkle starts only when the Info.plist has the public key that updates are signed with, so development builds never look for updates.

## Still open

- Whether a session stops watching the file system and closes its `cat-file` process while none of its tabs is visible.
- Whether yaga runs the git that `/usr/bin/git` stands for directly. That stub looks up the developer tools every time it runs, which made a short command take 13 ms instead of 6.4 ms.
- Whether yaga saves the login shell's `PATH` between launches, so that finding git doesn't wait for the user's shell to start.
- How much commit text the cache keeps, and whether that depends on the size of the repository.
- What the tab strip does when the tabs don't fit. The [main window](docs/main-window.md#still-open) lists the other open questions about the layout.
- Whether a command palette ships in release 1.
- Which keyboard shortcuts switch between History and Changes, since Command-1 to Command-9 already switch tabs.
