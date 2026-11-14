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

The mode `checks` doesn't time anything. It clicks a row, clicks it again, Shift-clicks, Command-clicks, clicks a row inside several selected, drags from one row to another and double-clicks, and `analyze.py` lists what each left selected, how many times the model was told and how many double-clicks the list reported. Run it with and without an experiment to see whether the experiment changes what a click does. The probe counts double-clicks rather than passing them on, because going to a commit would check it out in the test repository. Control-clicks aren't among the checks, because the menu they open would stop the probe.

The window opens on screen and takes the keyboard for about half a minute. The probe asks `measure.sh` to activate the copy with `open -a`, because an app started in the background can't make itself active.

Settings go through the environment:

| Variable | What it does |
| --- | --- |
| `ROGA_PROBE_HOLD` | Milliseconds between mouse-down and mouse-up. The default, 90, is about how long a click holds the button. |
| `ROGA_PROBE_GAP` | Milliseconds from one step to the next. The default is 700, which lets each commit's details load. |
| `ROGA_PROBE_SETTLE` | Seconds to wait once history shows. Give a large repository time to finish loading, such as 15 for Linux. |
| `ROGA_PROBE_SAMPLE` | `1` samples the main thread's stack about every half millisecond during each step, for `analyze.py --profile`. It slows the app slightly, so time without it. |
| `ROGA_PROBE_EXPERIMENT` | Changes to try without building the app, several separated by commas. See the list below. |

The experiments:

- `nopan` stops the history table's pan gesture recognizer from holding back the mouse-down.
- `nodelay` stops every gesture recognizer from the table up to the window's frame from holding back the mouse-down.
- `defer` tells the model about a new selection only once the frame with the highlight is committed.
- `nomodel` doesn't tell the model at all.
- `press` selects the clicked row when the button goes down, from a local event monitor, which sees the mouse-down before the gesture recognizers do.
- `mousedown` selects it when the table's `mouseDown(with:)` runs instead. It changes `NSTableView`'s own method for the history table only, so that `CommitTableView` doesn't look as if it overrides `mouseDown(with:)`. The table gets the press in time only with `nopan` too, so run it as `nopan,mousedown`.
- `override` gives `CommitTableView` a `mouseDown(with:)` that only calls `NSTableView`'s, as `override func mouseDown(with:)` calling `super` would. AppKit then handles clicks on the table without its gesture recognizers, the way it did before them: it selects the row on the press, tracks the mouse until the release, and tells the delegate the selection changed on the release.

`press` and `mousedown` act only on a plain single click on a row that isn't already the only one selected. Command-, Shift-, Control- and Option-clicks, double-clicks and clicks below the last row are left to AppKit. When the press has selected the row, its mouse-up doesn't report it to the model a second time.

## What the numbers mean

`analyze.py` reports each stage as a median, minimum and maximum over the steps, in milliseconds:

- **pressed → row selected**: from posting the mouse-down or key-down until AppKit marks the row's view as selected.
- **row selected → highlight drawn**: until the row view's `drawSelection(in:)` has run, which happens in the next frame AppKit draws.
- **highlight drawn → committed**: until the Core Animation commit with that drawing is done, as seen by a run-loop observer just after Core Animation's.
- **released → main thread free again**: from posting the mouse-up until the run loop next waits, after handling the mouse-up and committing whatever it set off.
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

## Numbers from 2026-11-14

Selecting on the press, measured against commit `39f7ec2` the same way as above. "Released → free" is from posting the mouse-up until the main thread next waits for an event.

| Run | Pressed → row selected | Row selected → highlight drawn | Pressed → committed | Pressed → on screen (estimate) | Released → free |
| --- | --: | --: | --: | --: | --: |
| Small, click | 96 | 46 | 147 | 181 | 53 |
| Small, click, again at the end | 96 | 51 | 149 | 184 | 57 |
| Small, click, `press` | 4.5 | 44 | 53 | 85 | 1.2 |
| Small, click, `press,defer` | 4.8 | 2.4 | 8.5 | 41 | 1.8 |
| Small, click, `override` | 5.2 | 0.7 | 7.6 | 40 | 51 |
| Small, click, `override,defer` | 5.5 | 0.6 | 7.7 | 41 | 51 |
| Small, click, `nopan,mousedown` | 96 | 46 | 146 | 179 | 53 |
| Linux, click | 96 | 46 | 146 | 175 | 51 |
| Linux, click, `press` | 5.5 | 43 | 53 | 86 | 0.5 |
| Linux, click, `press,defer` | 6.5 | 5.0 | 13 | 45 | 0.5 |
| Linux, click, `override` | 5.7 | 1.8 | 9.4 | 41 | 47 |
| Small, click, a build with `override func mouseDown(with:)` calling `super`, 20 steps | 2.6 | 0.5 | 4.4 | 38 | 30 |

With `press`, SwiftUI's update for the new selection moves to the press along with it, and the highlight waits for it there unless `defer` is on too. With `override`, AppKit tells the delegate on the release, so the update stays there. `nopan,mousedown` changes nothing, because while AppKit uses its gesture recognizers, the table's `mouseDown(with:)` doesn't run for a click at all: the tap recognizer selects the row on the release.

On 2026-11-13, `defer` and `nomodel` didn't make clicks faster because `clicked()` reports the row to the model again on the mouse-up, and neither experiment holds that back.

## What it doesn't cover

- Posted events skip the window server, so the time from the hardware to the app isn't included, for the probe or for the baseline.
- A posted click has no real mouse button, so the probe answers `+[NSEvent pressedMouseButtons]` for it while it holds the button.
- On 2026-11-14, three timing runs selected nothing, and the app's output said the click hit `CommitTableView` rather than one of its rows. Frames weren't being drawn during them. Running them again worked. The cause wasn't found, but all three were runs where AppKit tracked clicks without its gesture recognizers, so if a run reports that no steps selected their row, look for that line in `<log>.app.txt` and run it again.
- The screen here was a 60 Hz Studio Display. On a 120 Hz screen the commit times are the same, and the time from the commit to the screen is about half.
