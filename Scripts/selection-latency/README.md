# Selection latency

These scripts time selecting a row in history, from the click or the key press until the frame with the highlighted row is committed and shown, in a real copy of the app. They were made for [issue #83](https://github.com/tmarkovski/roga/issues/83).

- `probe.m` is a dylib that `measure.sh` loads into a test copy of Roga with `DYLD_INSERT_LIBRARIES`. It clicks rows or presses arrow keys by posting events to the app, which leaves the real pointer and keyboard alone, and records each stage on one clock. It can also sample the main thread's stack and try changes without building the app.
- `measure.sh` copies the app under its own bundle ID and home folder, opens it on a worktree, runs the probe, and cleans up after itself.
- `analyze.py` turns the probe's log into timings, and with `--profile` says what the main thread was doing.

## Running it

Build the app first, Release or Debug, for example into `build/`:

```sh
xcodebuild -project Roga.xcodeproj -scheme Roga -configuration Release -derivedDataPath build/dd \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

Give it a copy of a repository, because Roga writes commit-graph files into the repository it shows, and refresh the copy's index, or git hashes every file looking for changes:

```sh
git clone ~/src/some-repository /tmp/selection-small
cp -cR bench-repos/linux-commits /tmp/selection-linux   # APFS makes this cheap
git -C /tmp/selection-linux remote remove origin          # so nothing reaches the network
git -C /tmp/selection-linux update-index --refresh
```

Then run it, and read the log:

```sh
Scripts/selection-latency/measure.sh build/dd/Build/Products/Release/Roga.app /tmp/selection-small /tmp/click.log click 30
Scripts/selection-latency/measure.sh build/dd/Build/Products/Release/Roga.app /tmp/selection-small /tmp/keys.log keys 30
uv run Scripts/selection-latency/analyze.py /tmp/click.log /tmp/keys.log
```

The window opens on screen and takes the keyboard for about half a minute. The probe asks `measure.sh` to activate the copy with `open -a`, because an app started in the background can't make itself active.

Settings go through the environment:

| Variable | What it does |
| --- | --- |
| `ROGA_PROBE_HOLD` | Milliseconds between mouse-down and mouse-up. The default, 90, is about how long a click holds the button. |
| `ROGA_PROBE_GAP` | Milliseconds from one step to the next. The default is 700, which lets each commit's details load. |
| `ROGA_PROBE_SETTLE` | Seconds to wait once history shows. Give a large repository time to finish loading, such as 15 for Linux. |
| `ROGA_PROBE_SAMPLE` | `1` samples the main thread's stack about every half millisecond during each step, for `analyze.py --profile`. It slows the app slightly, so time without it. |
| `ROGA_PROBE_EXPERIMENT` | `nopan` stops the history table's pan gesture recognizer from holding back the mouse-down, `defer` tells the model about a new selection only once the frame with the highlight is committed, and `nomodel` doesn't tell it at all, and `nodelay` stops every gesture recognizer from the table up to the window's frame from holding back the mouse-down. Several can be combined with commas. |

## What the numbers mean

`analyze.py` reports each stage as a median, minimum and maximum over the steps, in milliseconds:

- **pressed → row selected**: from posting the mouse-down or key-down until AppKit marks the row's view as selected.
- **row selected → highlight drawn**: until the row view's `drawSelection(in:)` has run, which happens in the next frame AppKit draws.
- **highlight drawn → committed**: until the Core Animation commit with that drawing is done, as seen by a run-loop observer just after Core Animation's.
- **on screen (estimate)**: the screen shows a frame about one refresh after the window server picks it up, so this is the output time that the `CVDisplayLink` gives for the first refresh after the commit. It's an estimate, not a capture of the screen.

A frame is 16.7 ms at 60 Hz and 8.3 ms at 120 Hz.

The probe hooks classes by their Objective-C names, such as `_TtC9HistoryUI13CommitRowView`, and the controller's `tableViewSelectionDidChange:`. Renaming those types or that module needs the same change in `probe.m`, and the probe says in the app's output (`<log>.app.txt`) when it can't find them.

## Numbers from 2026-11-13

Measured against commit `c7a730f` on an M1 Max with macOS 27.0.1 and a 60 Hz Studio Display, 30 steps a run, medians in milliseconds. The small repository was a clone of Roga's own (303 commits), and the large one was the `linux-commits` bench repository (1.5 million commits). A click held the button for 90 ms.

| Run | Pressed → row selected | Row selected → highlight drawn | Released or key → committed | Released or key → on screen (estimate) |
| --- | --: | --: | --: | --: |
| Release, small, click | 100 | 48 | 55 | 85 |
| Release, small, arrow key | 4 | 46 | 56 | 87 |
| Release, small, arrow key, `defer` | 4 | 0.7 | 7 | 39 |
| Release, small, click, `defer` | 101 | 45 | 52 | 84 |
| Release, small, click, `nomodel` | 100 | 48 | 54 | 89 |
| Release, small, click, `nodelay` | 96 | 52 | 57 | 89 |
| Release, Linux, click | 96 | 44 | 47 | 80 |
| Release, Linux, arrow key | 4 | 53 | 59 | 91 |
| Release, Linux, arrow key, `defer` | 3 | 1.0 | 6 | 41 |
| Debug, small, click | 96 | 35 | 39 | 71 |
| Debug, small, arrow key | 3 | 40 | 45 | 78 |
| Debug, Linux, click | 97 | 57 | 60 | 93 |
| Debug, Linux, arrow key | 5 | 43 | 52 | 85 |

## What it doesn't cover

- Posted events skip the window server, so the time from the hardware to the app isn't included, for the probe or for the baseline.
- A posted click has no real mouse button, so the probe answers `+[NSEvent pressedMouseButtons]` for it while it holds the button.
- The screen here was a 60 Hz Studio Display. On a 120 Hz screen the commit times are the same, and the time from the commit to the screen is about half.
