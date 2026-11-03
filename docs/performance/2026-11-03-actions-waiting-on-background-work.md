# Actions that waited on background work

Measured on 2026-11-03, against commit `bddca90`, on an Apple M1 Max (8 performance cores, 2 efficiency cores, 64 GB) with macOS 27.0.1 and Xcode 27.2.

## What was reported

After opening the Linux repository and clicking through its uncommitted files, working in another repository felt slow. Switching branches took a while, and deleting a branch, local or remote, seemed to hang the UI a little. The guess was that git processes were blocking the UI, or that yaga was fetching or refreshing too many repositories.

## What we found

Git wasn't blocking the main thread. Actions that had already finished stayed busy, because they were waiting on work running at macOS's background priority, which is very slow on this machine. The guess about refreshing was right: every time yaga became active, it rescanned every repository.

## Results

Each range covers three runs of the old code and three of the new, alternating so that the machine's changing load affected both. These are Release builds, and every number is in milliseconds unless it says otherwise. [The full numbers](#every-run) are below.

| What someone does | Before | After |
| --- | --- | --- |
| Check out a branch in a small repository | 206–279 | 73–133 |
| Check out a branch just after switching back to yaga | 219–427 | 96–109 |
| Check out a branch in Linux | 2,626–3,614 | 386–469 |
| Delete a remote branch while a quiet fetch is running | 3,731–3,912 | 1,850–1,859 |
| Delete a remote branch with no fetch running | 1,798–1,842 | 1,366–1,850 |
| Delete a local branch | 86–110 | 105–112 |

In an earlier batch, when the machine was busier, the checkout just after switching back to yaga took 2,258 and 2,875 ms in two runs of three (273 ms in the third), against 73–78 ms with the fix to checkouts applied. That wait grows with the machine's load, so the table's "before" is close to its best case.

Remote deletions include a server that takes a second to answer, which the test added on purpose, and about 0.7 seconds of AppKit sliding the confirmation sheet in and out.

| What yaga does | Before | After |
| --- | --- | --- |
| Slowest `git status` on Linux during the run | 4.84–6.70 s | 0.53–0.59 s |
| Most `git status` commands running at once | 18 | 5 |
| Git processes started on the main thread | 281 of about 960 | 0 of about 940 |
| Git processes started by three switches back to yaga | about 300 | about 300 |
| Total main-thread stalls over 30 ms during the run | 2.8–2.9 s | 2.0–2.7 s |

The last two rows barely moved, and that's expected. A switch back to yaga still starts about 100 processes, though fewer now run at once. And main-thread stalls were never what was slowing these actions down, as the next sections explain.

## What caused it

**Background priority is very slow here.** `git status` took this long with each priority set by `taskpolicy`, with the machine's usual apps open:

| Repository | Normal | Utility | Background |
| --- | --- | --- | --- |
| Small (40 files) | 9 ms | 10 ms | 113–190 ms |
| Linux (88,000 files) | 385–414 ms | 383–431 ms | 5.6–7.0 s |

That's about 15 times slower, while utility priority costs almost nothing. Background work stays on the two efficiency cores, and shares them with whatever else on the machine is running there, such as photo analysis and Spotlight. So it has no upper limit. In one early run, on a machine made much busier by processes our own first test had left behind, `git status` on a 40-file repository took 60 to 240 seconds. That number is inflated and isn't typical, but it shows how far this can go.

**Checkouts waited for it.** A checkout finished with `await reportBranchChange()`, which reads the repository's worktrees and then runs `git status` in each of them at background priority, all before the checkout counted as done. While that ran, double-clicking another branch did nothing, and Delete was disabled or silently ignored, because `BranchModel.isBusy` was still true. Making a new branch waited in the same way.

**Linux slowed down other repositories.** Every repository's background `git status` competes for the same two cores, and Linux's is by far the largest. With Linux removed from the list, the checkout just after switching back took 190–199 ms, against 273–2,875 ms with it. The scan reaches every listed repository, so this applies whether or not Linux has been opened. We didn't test those two cases separately.

**Every switch back to yaga rescanned everything, with nothing to stop a scan already running.** That's about 100 git processes for 16 repositories. In one run, three switches 1.5 seconds apart ran three scans of Linux at once, each taking 9–12 seconds rather than 0.4.

**Remote deletions waited for quiet fetches.** Pulling, pushing, fetching and deleting from a remote all waited for any running fetch, including the quiet one that starts when a window shows a repository, at background priority. Delete a remote branch soon after arriving at a repository, and it waited for that fetch to finish. With a server that takes 4 seconds to answer, that added about 2 seconds. The limit on a quiet fetch is a minute.

## What wasn't the cause

- **Starting git on the main thread.** Session functions that weren't `@concurrent` ran on the main actor when a model called them, so 29% of git processes did start there. But `posix_spawn` took about 0.5 ms, and the worst was under 4 ms, or 24–27 ms under a debugger. It was worth moving, but nobody could feel it.
- **Deleting itself.** A local deletion took about 100 ms in every run, including during scans.
- **The stall of about 670 ms on a remote deletion.** That's `-[NSMoveHelper _doAnimation]` sliding the confirmation sheet in and out. About three quarters of the samples are waiting for the next event inside its nested run loop.
- **Debug builds.** They showed the same pattern and much the same timings. A debugger added about 70% more stall time, mostly at launch, plus a pause of about 500 ms once in each run.

## What changed

1. `RepositoryList.refresh(repositoryAt:)` now returns once it has read the worktrees, and the rest carries on behind it. So checkouts and new branches no longer wait for the counts.
2. Only one look at a repository runs at a time, and asking during one looks once more when it's done. Four repositories get looked at at once, and the others wait for their turn.
3. `GitCommand.priority` replaces `runsAtLowPriority`, and adds utility priority. The sidebar's counts and quiet fetches use it. Updating the commit-graph files stays at background priority, because it uses far more CPU than anything else yaga runs.
4. What someone asks for now stops a quiet fetch rather than waiting for it, and a stopped fetch doesn't count toward the minute between fetches. A fetch someone asked for still runs to its end.
5. `Git.run` and the session's nonisolated functions are `@concurrent`, and so are starting a session and finding git, so all of it leaves the main thread.

Tests cover the counts not holding anything up, looks being merged and limited, and quiet fetches being stopped. Nothing automated checks that git stays off the main thread, because that needs the probe described below.

## How this was measured

A scripted driver hosted the real `WorkspaceView` in an off-screen window and called the real models, in the order the report described: open Linux, select its uncommitted row and four files, switch to another repository, delete a remote branch 1.5 seconds after arriving, check out three branches, delete two local branches, delete another remote branch, switch back to yaga three times, and then do the same kinds of thing again, including on Linux.

A dylib loaded with `DYLD_INSERT_LIBRARIES` logged each time the main thread stayed busy for over 30 ms, with samples of its stack, and each `posix_spawn` with its thread and duration. Timing came from each action's start until the model stopped being busy, and durations of git commands from `CommandLog`.

The list had 16 repositories: an APFS copy of the `linux-commits` bench repository (1.5 million commits, 957 refs, 13 changed files) and 15 generated ones of 40 commits. The repository under test had a local bare remote behind scripts that wait 4 seconds before a fetch and 1 second before a push, to behave like a real server.

The real app target was also built from the new code and run as a copy with its own bundle ID on these repositories. Its sidebar filled in as usual, with 151 git processes started and none on the main thread.

### What this doesn't cover

- The driver called models directly rather than clicking, so it doesn't measure real menus or gestures.
- It hasn't been measured on the 17 repositories and 25 worktrees that first showed the problem, or with a real server.
- That Delete was disabled or ignored during a checkout comes from reading the code, not from clicking it.
- Machine load swung a lot through the day, with a load average from about 7 to over 50, and it changes the "before" numbers much more than the "after" ones.

Some traps for anyone repeating this: a copied repository has a stale index, and yaga's `--no-optional-locks` means nothing refreshes it, so run `git update-index --refresh` in the copy first. Without that, `git status` hashes every file, and listing the uncommitted files of the partial clone of Linux hadn't finished after four minutes, most likely because `git diff-files` was downloading blobs. A driver that calls `exit` also leaves its git processes running, which starves later runs. Those two together produced the 60–240 second figures above.

## What's left

- A switch back to yaga still starts about 100 git processes. Live refresh from file system events, which [ARCHITECTURE.md](../../ARCHITECTURE.md) already plans, would remove most of them.
- Switching repositories stalls the main thread for 150–200 ms while SwiftUI rebuilds the view, in both Debug and Release.
- Deleting a local branch on Linux went from 128–155 ms to 213–219 ms in the table below. Most likely that's because it now starts right after the checkout before it, while history and the refs panel are still reloading, where it used to start about 3 seconds later. We didn't test this separately.

## Every run

Times in milliseconds, for the final code. `before` and `after` are Release builds, run in the order 1, 1, 2, 2, 3, 3. The last two columns are Debug builds under lldb, as when running from Xcode. The first row in Release is 0 because history had already loaded by the time the run asked for it. That isn't a measurement.

| Action | before 1 | before 2 | before 3 | after 1 | after 2 | after 3 | before, debugger | after, debugger |
| --- | --: | --: | --: | --: | --: | --: | --: | --: |
| Linux: history and refs loaded | 0 | 0 | 0 | 0 | 0 | 0 | 7,848 | 8,058 |
| Linux: uncommitted files listed | 583 | 563 | 592 | 560 | 562 | 602 | 530 | 544 |
| Other repository: history and refs loaded | 119 | 161 | 168 | 97 | 160 | 189 | 142 | 171 |
| Delete remote, with a quiet fetch running | 3,908 | 3,731 | 3,912 | 1,852 | 1,850 | 1,859 | 3,795 | 1,857 |
| Check out feature-a | 222 | 265 | 270 | 91 | 133 | 122 | 282 | 97 |
| Check out feature-b | 206 | 226 | 265 | 73 | 107 | 117 | 259 | 580 |
| Check out main | 279 | 237 | 277 | 102 | 109 | 127 | 301 | 140 |
| Delete local, first | 86 | 107 | 109 | 107 | 107 | 109 | 108 | 127 |
| Delete local, second | 108 | 106 | 110 | 106 | 107 | 109 | 134 | 107 |
| Delete remote, no fetch running | 1,835 | 1,798 | 1,842 | 1,366 | 1,850 | 1,845 | 1,816 | 1,828 |
| Delete local, after switching back to yaga | 105 | 106 | 109 | 106 | 112 | 105 | 128 | 107 |
| Check out, after switching back to yaga | 362 | 219 | 427 | 96 | 98 | 109 | 326 | 94 |
| Linux: check out | 2,640 | 2,626 | 2,845 | 389 | 402 | 418 | 2,501 | 439 |
| Linux: check out, back again | 2,817 | 2,670 | 3,614 | 386 | 469 | 398 | 2,664 | 454 |
| Linux: delete local | 128 | 128 | 155 | 219 | 213 | 216 | 180 | 264 |

The 580 ms under the debugger is a pause of about 470 ms that also appeared in the old code's debugger run, in a stall where the probe got only one sample.

| Across the whole run | before 1 | before 2 | before 3 | after 1 | after 2 | after 3 | before, debugger | after, debugger |
| --- | --: | --: | --: | --: | --: | --: | --: | --: |
| Stalls over 30 ms | 20 | 20 | 17 | 16 | 17 | 15 | 31 | 24 |
| Their total (ms) | 2,839 | 2,891 | 2,816 | 1,991 | 2,586 | 2,733 | 4,749 | 4,140 |
| Worst stall (ms) | 703 | 720 | 715 | 714 | 692 | 690 | 1,000 | 963 |
| Git processes | 961 | 959 | 959 | 939 | 960 | 934 | 959 | 939 |
| Of those, on the main thread | 281 | 281 | 281 | 0 | 0 | 0 | 281 | 0 |
| Slowest `posix_spawn` on the main thread (ms) | 3.5 | 3.0 | 3.6 | – | – | – | 23.9 | – |
| Most `git status` commands at once | 18 | 18 | 18 | 5 | 5 | 5 | 18 | 5 |
| Slowest `git status` on Linux (s) | 4.88 | 4.84 | 6.70 | 0.53 | 0.56 | 0.59 | 4.46 | 0.59 |
| Median `git status` on Linux (s) | 0.43 | 0.43 | 0.44 | 0.42 | 0.42 | 0.42 | 0.43 | 0.42 |
