# Launch time

These scripts time Roga's launch in a real copy of the app, from the moment the kernel starts the process until the window has drawn history's rows, and say what happened on the way: when the window was ordered onto the screen and committed its first frame, when the login shell and each git ran, and, when asked, what the main thread was doing.

- `probe.m` is a dylib that `measure.sh` loads into a test copy of Roga with `DYLD_INSERT_LIBRARIES`. It records the milestones on one clock, and every child process the app starts, with its arguments and when it ended, by interposing `posix_spawn`. Half a second after history's rows first draw, it writes its log and ends the app.
- `fixture.sh` makes the repositories the test copy lists, as clones, because Roga writes commit-graph files into the repositories it shows.
- `measure.sh` copies one or more builds of the app under their own bundle ID and home folder, launches each in turn, and cleans up after itself.
- `analyze.py` turns the logs into timings, compares builds, lists one run's timeline, and with `--profile` says what the main thread was doing.

## Running it

Build the app, Release, for example into `build/`:

```sh
xcodebuild -project Roga.xcodeproj -scheme Roga -configuration Release -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

Make the repositories once. The second and later arguments are a small repository, a medium one and a large one to clone. A local clone links the objects, so even Linux takes only as long as checking out its files:

```sh
Scripts/launch-time/fixture.sh /tmp/launch-fixture ~/src/roga bench-repos/git bench-repos/linux
```

That makes 16 repositories, shaped like a sidebar that's been used for a while: three expanded, the first with three linked worktrees as agents would leave it, and the rest collapsed.

Then launch one or more builds, here 12 times each, with the clone of Roga selected:

```sh
Scripts/launch-time/measure.sh /tmp/launch-fixture /tmp/launch-logs 12 roga base=/tmp/Roga-before.app new=build/DerivedData/Build/Products/Release/Roga.app
uv run Scripts/launch-time/analyze.py /tmp/launch-logs/base /tmp/launch-logs/new
uv run Scripts/launch-time/analyze.py /tmp/launch-logs/new --timeline 3
```

Copy a build somewhere before building the next, since Xcode builds into the same place. The fourth argument chooses the repository to select, such as `large` for Linux.

Each build launches once to warm up before its runs, because the first launch after a build is slower: dyld has no closure for it yet and its pages aren't in memory. With more than one build, their runs take turns, so that whatever else the Mac is doing slows them alike. Each run starts from the same list of repositories, saved with the bookmarks and owners the warm-up wrote, and before the next run starts, the git processes the last one started are given up to 30 seconds to finish.

The window opens on screen for a second or two each run. It isn't made active, so it may open behind other windows, which doesn't change when it draws.

The login shell that Roga starts to read `PATH` gets the real home folder, through the probe, so that it reads the real dotfiles and takes as long as it does for Roga itself. Everything else in the copy has the test home folder.

Settings go through the environment:

| Variable | What it does |
| --- | --- |
| `ROGA_PROBE_SAMPLE` | `1` samples the main thread's stack about every half millisecond, for `analyze.py --profile`. It slows the app slightly, so time without it. |
| `ROGA_PROBE_SHELL_HOME` | The home folder the login shell gets. It's the real one by default. Set it to nothing to leave the shell with the test home folder, which has no dotfiles. |
| `ROGA_PROBE_TIMEOUT` | Seconds to wait for history's rows before giving up on a run. The default is 20. |

## What the numbers mean

Every time is in milliseconds from when the kernel started the process, which the probe reads with `sysctl`.

- **probe loaded**: the probe's constructor ran, which is once dyld has loaded every library and before the app's own code.
- **will finish launching** and **did finish launching**: AppKit's notifications. Roga's `App.init` runs before the first.
- **window ordered in**: `orderWindow:relativeTo:` returned for the workspace window.
- **window's first frame committed**: the end of the run-loop pass after the window was ordered in, which is when Core Animation has sent its first frame to the window server. The screen shows it about one refresh later.
- **login shell started** and **ended**: the shell Roga starts to read `PATH` (decision 3).
- **first `git version` ended**: Roga has found a git it can use.
- **first repository git started**: the first git that isn't `git version`, which is a repository opening.
- **history rows drawn** and **history on screen**: the first `CommitCellView` drew, and the run-loop pass with it ended.

With `--profile`, `analyze.py` splits the launch into stretches and says, for each, what share of the main thread's samples went where, which functions were on the stack, and, with `--tree`, a call tree from the root down. Functions in the app's own binary are named with `atos` from the dSYM next to the app that `measure.sh` noted in `app-path`.

The probe hooks `_TtC9HistoryUI14CommitCellView`'s `drawRect:`. Renaming that class or its module needs the same change in `probe.m`, and the probe says in the app's output (`<log>.app.txt`) when it can't find it.

## What it doesn't cover

- A launch from the Dock or Finder goes through LaunchServices, which adds its own time before the process starts and makes the app active. The test copy is started directly, because LaunchServices would drop `DYLD_INSERT_LIBRARIES`.
- Cold launches, after `sudo purge` or a restart, aren't measured. The warm-up's numbers, the first launch after a build, are the closest.
- The timings depend on everything else running on the Mac. Compare builds in one interleaved run of `measure.sh`, not across runs made at different times.
