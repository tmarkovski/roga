# Launch time

Measured on 2026-11-23, against commit `3757b63`, on an Apple M3 (4 performance cores, 4 efficiency cores, 24 GB) with macOS 27.0.1 and Xcode 27.2, using the scripts in [Scripts/launch-time](../../Scripts/launch-time/README.md).

## What was asked

How long Roga takes from launch until its window shows and has drawn what it's for, and whether moving work at launch off the critical path, as repositories already load in the background, would make that faster.

## What we found

There are two answers, because the window comes up long before it has anything to show.

**The window's first frame was committed about 360 ms after the process started, and Roga's own code is a few milliseconds of that.** Sampling the main thread every half millisecond over five launches:

| From | To | Main thread | Where the time went |
| --- | --- | --: | --- |
| Process start | dyld done | 15 ms | Loading libraries. |
| dyld done | `applicationWillFinishLaunching` | 70 ms | `App.init`, 60 ms of it in `AppTheme.applyStored()`, which is `NSApplication.shared` being created the first time it's asked for. SwiftUI would create it a moment later otherwise. The rest of `App.init`, Sparkle and reading `repositories.json` included, is about 7 ms. |
| `applicationWillFinishLaunching` | window ordered in | 180 ms | SwiftUI handling the open-application Apple event by creating the window (95 ms), building the menu bar (37 ms), and waiting for the window server and other processes to answer (54 ms). |
| Window ordered in | first frame committed | 130 ms | SwiftUI laying out the window (100 ms) and waiting for the window server (27 ms). Roga's own view bodies, the sidebar's included, add up to under 10 ms. |

Nothing Roga does synchronously at launch is worth moving off the main thread. `App.init` reads one small JSON file and some defaults, and everything slow already runs in tasks.

**History's rows drew about 970 ms after the process started, and for most of that time the main thread was idle.** Between the first frame and history, 56% of the main thread's samples were waiting for an event. What it was waiting for, from the timeline of every process the app started:

1. **The login shell, about 400–450 ms.** Roga starts `zsh -i -l` to read `PATH` (decision 3), and with the dotfiles on this Mac that takes 320 ms on its own and longer while the app is launching. git can't be looked for until it's done.
2. **Every repository opening at once, about 300 ms.** Once git answered `git version`, all 16 repositories started opening together: 32 `rev-parse`, 16 `cat-file --batch-command` and 16 `worktree list`, along with three `git version` for the survey of every git and `--version` for each copy of Claude Code and Codex. The selected repository's `worktree list` took 150–190 ms instead of the 30 ms it takes alone, and its history couldn't start loading until it was done.
3. **Loading the selected worktree's history, about 60 ms,** with its refs, `worktree list` and settings, which ran alongside the other repositories' commands.

## What changed

All of it is [decision 97](../decisions/0097-start-from-last-launchs-path-and-open-the-shown-repository-first.md).

1. Roga saves the `PATH` the login shell says, and at launch it looks for git in the saved one while the shell runs again in the background. The first launch, and Look Again, still wait for the shell.
2. The repositories that windows show open before the rest: the one the window that connects shows, and the one selected last. The others start once those have, or after half a second if they're slow.
3. When git was found in the saved `PATH`, the shell runs at utility priority, since nothing waits for it. Started at normal priority alongside the repositories, it hadn't finished 0.7 seconds later, against 0.4 seconds when it ran first.

Tests cover finding git in the saved `PATH` before the shell answers, finding it again only when the shell says something else, keeping the saved `PATH` when the shell says nothing, Look Again waiting for the shell, the shell's priority, the shown repositories listing their worktrees before git runs in any other, and the half-second limit.

## What didn't help

**Opening the repositories from the app as soon as git was found,** rather than from the window's `.task` once it appeared. With the saved `PATH`, `git version` answers at about 165 ms, and the window's `.task` ran at about 380 ms, so this looked like it would save 200 ms. It saved nothing: the first repository's git started at 378 ms rather than 387. The timeline shows why. AppKit handles the open-application event, and SwiftUI creates, lays out and commits the window, in a single pass of the main run loop, which ran without a break from about 150 ms to the first frame at 357 ms in the run looked at. Nothing on the main actor runs until that pass ends, including the provider taking the git it found and the list starting to open repositories. So the change was taken out.

## Results

History now shows about 0.4 seconds sooner, whichever repository is selected, and the slowest launch with the changes was quicker than the quickest without them. The window itself comes up when it did.

Release builds, warm launches, medians in milliseconds from the process starting, with the fastest and slowest run in brackets. Each pair of columns took turns in one run of `measure.sh`.

| Milestone | Before, small repository selected | After | Before, Linux selected | After |
| --- | --: | --: | --: | --: |
| Window's first frame committed | 378 (350–404) | 363 (320–435) | 364 (332–394) | 352 (337–373) |
| Git found | 577 (547–591) | 179 (152–242) | 557 (545–587) | 170 (158–189) |
| First git in a repository | 601 (559–615) | 395 (348–480) | 573 (566–601) | 380 (364–403) |
| History on screen | 945 (788–1,046) | 556 (494–623) | 946 (801–973) | 551 (528–588) |

The small repository columns are 12 launches of each build, and the Linux columns 8. History on Linux shows as soon as on a small repository because the first screen of it comes from the commit-graph file, which takes about the same time at any size.

Each change on its own, from two earlier runs with the small repository selected, 12 launches of each build:

| Build | History on screen |
| --- | --: |
| Before | 970 (792–1,046) and 972 (935–1,061) |
| The saved `PATH` | 678 (605–800) |
| And the shown repository first | 558 (521–582) and 548 (501–635) |
| And opening repositories from the app, and the shell at utility priority | 535 (488–573) |

The last row is the build with the change that was taken out, as [What didn't help](#what-didnt-help) explains, so the final build is between the last two rows.

With the changes, the 190 ms or so from the window's first frame to history is mostly the main thread. Over five sampled launches, 73% of its samples in that stretch were SwiftUI updating views, 19% waiting for an event and 5% waiting for other processes. Roga's own view bodies, the sidebar's rows most of all, are a few milliseconds each. The rest is SwiftUI's own work as 16 repositories change state one after another and the window goes from its spinner to history.

## How this was measured

`measure.sh` copies each build of the app under a test bundle ID and home folder, so the real Roga's settings and repositories are left alone, and launches it directly with a probe loaded through `DYLD_INSERT_LIBRARIES`. The probe records each milestone on one clock from the kernel's start time for the process, and every `posix_spawn` with its arguments and when the process ended. It ends the app half a second after history's first row draws. Each build was launched once to warm up, and then the builds took turns, 12 launches each, so that whatever else the Mac was doing slowed them alike. Before each launch, the script waited for the git processes the last one left behind to end.

The sidebar listed 16 repositories, clones made by `fixture.sh`: 14 of Roga's own repository (about 300 commits and 1,000 files), the `git` bench repository (82,000 commits) and the Linux bench repository (1.5 million commits, 97,000 files). Three were expanded, and the first had three linked worktrees, as agents would leave it. The list was the one the warm-up saved, with a bookmark for each repository, as a list that's been opened before has. The login shell was given the real home folder, so it read the real dotfiles and took as long as it does for Roga.

### What this doesn't cover

- These are warm launches. The warm-ups, each the first launch of a freshly copied and signed build, varied too much to compare: history showed after 1.0 to 4.9 seconds in the old build, whose warm-up always ran first, and 0.7 to 1.3 seconds in the new ones. A cold launch after a restart wasn't measured.
- A launch from the Dock goes through LaunchServices first, which adds time before the process starts and makes Roga active. The test copy was started directly, and never became active.
- The Mac was busy with other work throughout, with a load average between 7 and 20, mostly from `secd` and the Passwords app. Interleaving the builds keeps the comparison fair, but the absolute numbers are higher than on an idle Mac.
- Restored windows weren't measured. The test passes `-ApplePersistenceIgnoreState YES`, so each launch opens one new window on the selected worktree.

## What's left

- **SwiftUI's updates after the first frame.** Between the window's first frame and history, the main thread spends about 140 ms in SwiftUI updates as each of the 16 repositories opens and as the window changes from its spinner to history. Fewer, larger changes to the list's state, or rows that read less of it, might shorten that. It needs its own look, with SwiftUI's instruments.
- **Opening the selected repository while the window is made.** The window takes a single 200 ms pass of the main run loop, and nothing on the main actor runs during it. Opening the selected repository and reading the first screen of its history entirely off the main actor, from `App.init`, could have history ready at the first frame. It would mean loading a repository before any model exists to hold it.
- **The window's first frame,** at about 360 ms, is AppKit and SwiftUI creating the window and the menu bar. Making it sooner would mean less for SwiftUI to build in the first frame, such as fewer menu commands or a simpler view before the repositories open, and it isn't clear how much that would save.
- **The first launch** has no saved `PATH`, so it still waits for the shell.
