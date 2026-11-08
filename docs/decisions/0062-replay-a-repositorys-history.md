# 62. Replay a repository's history, drawn in Swift

Accepted on 2026-11-08. It isn't scheduled yet, and nothing in it is built. The [roadmap](../../ROADMAP.md) lists it as decided but not scheduled.

## Context

We want a way to watch a repository's history play out: a branch leaves the main line, its commits land one by one, and it merges back, with the camera following along. It's for any repository the user has open, whenever they want it, and not a one-off video for the landing page. It's also something people can share, which helps people find Roga.

Other tools have done this, and the ones that spread, such as Gource, GitHub Unwrapped and Learn Git Branching, have a few things in common. Each leaves people with one thing to post, such as a video, an image or a link. Each is about the person's own work. And each takes almost no effort to start. Developers also like history drawn as a metro map. The [history replay prototype](../../prototypes/history-replay/README.md) lists what we looked at.

We tried the motion in a browser first, as we did for the house's walk ([decision 21](0021-draw-the-houses-animations-from-joints.md)), on this repository and on the last two weeks of VS Code. The prototype's README has what that showed. In short:

- Everything the replay needs is already loaded somewhere in the app: parents and commit times from the commit-graph reader, subjects and merge messages from the `cat-file` process, and branch names from the refs.
- git doesn't record which branch a commit was made on, so the replay has to work that out. Taking the main line as the chain of first parents is right for this repository, but VS Code's history defeated it. One merge had `main` as its second parent, and the replay showed a single "branch" of 1,077 commits that ran for six minutes.
- Squashed and rebased pull requests leave no branch in the history. 766 of the 946 commits on VS Code's main line are squashed pull requests.
- At a fixed pace, this repository plays for 48 seconds, but two weeks of VS Code would play for seven minutes.

We considered drawing the replay as a web page in a web view, since the prototype already is one. The [vision](../../VISION.md) rules out web views standing in for native UI, and we'd be keeping two ways of drawing the same thing.

## Decision

**The replay is drawn in Swift, with a SwiftUI `Canvas` in a `TimelineView`, the way the house is.** The prototype stays a motion study, and Roga doesn't ship it.

**It replays the branch on screen, in whatever repository is open.** **Replay History** in the Branch menu replays the current branch, and the same command in a branch's menu, in history or the refs panel, replays that one. It plays with a play button, a slider to scrub through it, and a choice of speed. Space plays and pauses, and the arrow keys jump back and forward.

**It looks like a metro map.**

- The main line runs across the middle, in ink. Each branch gets a lane above or below it, nearest first, and a lane is free again once its branch has merged.
- A branch's line curves off the commit it started from, runs along its lane, and curves back into its merge. The lanes take turns with the graph's Monokai colors ([decision 27](0027-give-the-graph-and-branches-monokais-colors.md)).
- A merge into the main line is drawn as an interchange, and sends out a ring in the color of the branch it brought in. A pull request that was squashed onto the main line is drawn as an interchange too, since its branch is gone.
- Each branch is labeled with its pull request's number and title, or its name when there's no pull request. The label fades once the branch has merged.
- The date and how many commits, branches and merges have landed so far are at the top. The newest commit's hash and subject are at the bottom.
- At the end, the camera pulls back to show the whole range at once, with a summary over it such as **209 commits · 27 branches · 8 days**.

**Roga works out the branches from the history, because git doesn't record them.**

1. The main line runs back from the tip of the branch being replayed, through each commit's first parent. At a merge, it follows the second parent instead when the merge's message says it brought in the branch being replayed, or when more pull requests landed on that side.
2. Each merge on the main line brings in a branch. Its commits are the ones behind the merge's other parents that no earlier branch has claimed.
3. A merged branch's name comes from the merge's message. GitHub writes `Merge pull request #52 from owner/branch` with the pull request's title in the body, GitLab writes `Merge branch 'x' into 'main'`, and Bitbucket writes `Merged in x (pull request #12)`. GitHub can also be set to use the pull request's title as the subject, followed by its number. A branch that hasn't merged yet takes its name from its ref.

**A replay has a length rather than a speed.** The user picks a range, such as the last two weeks, everything since a tag, or the whole history, and how long the replay plays. Stretches where no branch is open get a quarter of the time. Then the whole replay speeds up to fit the length, and the camera pulls back to match, so that it never pans faster than anyone can read. The range matters more than the length: a replay of all of Linux's million commits wouldn't mean anything.

**Each frame depends only on its time.** The camera follows an average of where the newest commit was over the last half second, rather than easing toward it frame by frame. So playing, scrubbing and saving all draw the same frame for the same moment.

**Roga saves a replay as a video and its last frame as an image.** It draws each frame on its own with `ImageRenderer`, faster than real time, and writes them as an MP4 with `AVAssetWriter`. The last frame is saved as a PNG. Both are part of macOS.

**Someone who asks for less motion sees the last frame, still**, as with the house. VoiceOver reads the summary, and every control names itself.

**The code goes where the layers say.**

- Working out the replay is a type in `CommitGraph`, next to `LaneLayout`. It takes the graph, the tip, the range and the commits' subjects, and returns the branches, their lanes, and when each commit lands. It doesn't use AppKit, so it's tested against the fixture repositories and timed in `roga-bench`. It's the prototype's `build()`, in Swift.
- The repository's session loads the subjects and merge messages for the range through the `cat-file` process, since views never run git.
- Drawing, playing and saving the replay go in `RogaUI`, in a folder of their own, as the house's code is.

## Consequences

- Nothing new is linked except AVFoundation, which comes with macOS. `RogaUI`'s row in the architecture's table of modules gains it when the replay is built.
- The replay guesses which commits made up each branch, and a history can still fool it. The guess is only used here, so history everywhere else in Roga stays exactly what git says.
- A repository that squashes every pull request replays as one straight line of interchanges. A lane for each author might say more for those, since it would still show who did the work when the branches are gone. That's left for later.
- Deciding which side of a merge is the main line walks both sides. The prototype walks all of each side, which won't do for a large repository. Roga has to bound the walk with generation numbers, the way `HistoryOrder` does, and `roga-bench` has to show that a replay of a large repository is worked out quickly.
- The notes under merges crowd each other when merges come close together, which the prototype doesn't solve. Roga has to skip or move a note that would overlap another before this ships.
- How long a minute of video takes to save hasn't been measured.
- The timings and sizes in the prototype, such as how long a line takes to reach its commit and how far apart the lanes are, are where the Swift version starts.
- It's about two weeks of work for one person:
  - two or three days for working out the replay, with its tests;
  - three or four for drawing it, with the camera, the labels and the controls;
  - two for saving videos and images;
  - two for the range and length, less motion, VoiceOver, and both appearances.
- These are still open:
  - whether the replay plays in its own window or over the history in the main window
  - what range and length a replay starts with
  - whether the house walks along the main line ahead of the newest commit, the way it does on the landing page
  - what to show for a repository that squashes every pull request
  - whether to offer a video shaped for phones (9:16) as well as a wide one
