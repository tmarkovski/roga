# History replay

This is a throwaway motion study for a feature that replays a repository's history as an animation: a branch starts, its commits land one by one, and it merges back, with the camera following along. It isn't part of the app. The app would draw the replay natively, but a page in a browser was the quickest way to try the motion on real histories, the same way the house's walk was tried first ([decision 21](../../docs/decisions/0021-draw-the-houses-animations-from-joints.md)).

## Running it

Open `index.html` in a browser. It replays this repository's `main`, from `history.js`.

To replay another repository, export its history first, and open the page again:

```bash
prototypes/history-replay/export-history.sh ~/src/some-repo main
```

The script overwrites `history.js`, so run it with no arguments afterward to go back to this repository.

The page takes these options in its address:

- `?length=60` sets the longest the replay plays, in seconds, before the zoom out at the end. It's 75 unless you say otherwise.
- `?speed=2` starts it at twice the speed.
- `?t=12` opens it at 12 seconds, paused, which is handy for screenshots.

Space plays and pauses, and the arrow keys jump 2 seconds back or forward. **Record** plays the replay from the start and saves it as a video.

## What it shows

- The main line runs across the middle. Each branch gets a lane above or below it, nearest first, the way a metro map draws its lines. A lane is free again once its branch has merged, so lanes get reused.
- A branch's line curves off the commit it started from, runs along its lane, and curves back into its merge. The lanes take turns with the graph's eight Monokai colors (decision 27), and the main line is drawn in ink so that the branches stand out.
- A merge into the main line is drawn as an interchange, with a ring in the merged branch's color. A pull request that was squashed onto the main line is drawn as an interchange too.
- Each branch is labeled with its pull request's number and title, and the label fades once it has merged.
- The top shows the date and how many commits, branches and merges have landed so far. The bottom shows the newest commit's hash and subject.
- Stretches where no branch is open, like the first days of this repository, fast-forward.
- At the end, the camera pulls back to show the whole history at once, with a summary over it. That last frame works as an image to share.
- Someone who asked for less motion starts on that last frame, still.

## What we learned

**Everything the replay needs is already in the app.** The commit-graph reader gives each commit's parents and commit time. The `cat-file` process gives subjects and the first line of each merge's body. The refs give the names of branches that haven't merged yet. Nothing new has to be read from the repository.

**git doesn't record which branch a commit was made on, so the replay has to work it out.** The prototype does it this way:

1. The main line runs back from the tip of `main`, usually through each commit's first parent.
2. Each merge on the main line brings in a branch. Its commits are the ones behind the merge's other parents that no earlier branch has claimed.
3. The branch's name comes from the merge's message. GitHub writes `Merge pull request #52 from owner/branch` with the pull request's title in the body, GitLab writes `Merge branch 'x' into 'main'`, and Bitbucket writes `Merged in x (pull request #12)`. GitHub can also be set to use the pull request's title as the subject, followed by its number.

That guess is right for this repository. It isn't always right:

- **The first parent isn't always main.** When someone pulls `main` into a branch and pushes the result, `main` ends up as the second parent. Trying the last two weeks of VS Code (1,366 commits from 85 people) showed this. One merge's first parent led away from the main line, and the replay showed a single "branch" of 1,077 commits that ran for six minutes. The prototype now follows the second parent at a merge when the merge's message says it brought in `main`, or when more pull requests landed on that side. With that, VS Code shows 156 branches, the longest with 14 commits.
- **Squashed and rebased pull requests leave no branch behind.** 766 of the 946 commits on VS Code's main line are squashed pull requests, so most of its work shows as interchanges along a straight line rather than as branches. The replay can't show branches that git doesn't have. For a repository that squashes everything, a lane for each author, the way Gource shows people, would say more. That's worth trying later.

**A replay needs a length, not a speed.** At a fixed pace, this repository plays for 48 seconds, but two weeks of VS Code would play for seven minutes. The prototype gives quiet stretches a quarter of the time, then speeds the whole replay up to fit 75 seconds, and pulls the camera back to match so that it doesn't pan faster than anyone can read. The labels still crowd when merges come close together, which a real version would need to fix, for example by skipping notes that would overlap.

**Each frame depends only on its time.** The camera follows an average of where the newest commit was over the last half second, rather than easing toward it frame by frame. So playing, scrubbing and recording all draw the same frame for the same moment. This is what makes saving a video simple in the app: it can draw each frame on its own, faster than real time.

## Building it in the app

The replay fits the app's layers without changing them.

- **Working out the replay** goes in `CommitGraph`, next to `LaneLayout`, as a type that takes the graph, the tip, a range and the subjects, and returns the branches, their lanes, and when each commit lands. It's the prototype's `build()` in Swift. It needs no AppKit, so it can be tested against the fixture repositories and run in `roga-bench`. Deciding which side of a merge is main has to walk each side, which generation numbers can bound the same way they bound `HistoryOrder`.
- **Drawing it** goes in `RogaUI`, as a SwiftUI `Canvas` inside a `TimelineView`, the way the house is drawn. A replay is a function from time to a frame, just as each of the house's animations is a function from time to a pose. It takes the lane colors from `GitColors`, and it starts on the last frame for someone who asked for less motion.
- **Saving it** draws each frame with `ImageRenderer` and writes them with `AVAssetWriter` as an MP4, and saves the last frame as a PNG. Both are part of macOS, so there's no new dependency. We haven't measured how long a minute of video takes to render.

It would open from a **Replay History** command in the History menu and from the menu of a branch, and play in its own window, for whichever repository and branch is on screen. The window would offer a range, such as the last two weeks, since a tag, or the whole history for a small repository, and a length. Replaying all of Linux's million commits wouldn't mean anything, so the range matters more than speed.

**Rough size**, for one person: two or three days for working out the replay, with tests; three or four for drawing it, with the camera, labels and controls; two for saving videos and images; and two for the range picker, less motion, VoiceOver, and both appearances. That's about two weeks in all.

**Still open:**

- whether the replay belongs in its own window or over the history in the main window
- whether the house should walk along the main line ahead of the newest commit, the way it does on the landing page
- what the replay should show for a repository that squashes every pull request
- whether to offer a version shaped for phones (9:16) as well as a wide one
