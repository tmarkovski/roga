# History replay

This is a throwaway motion study for a feature that replays a repository's history as an animation: a branch starts, its commits land one by one, and it merges back, with the camera following along. It isn't part of the app. [Decision 62](../../docs/decisions/0062-replay-a-repositorys-history.md) has the app draw the replay in Swift, but a page in a browser was the quickest way to try the motion on real histories, the same way the house's walk was tried first ([decision 21](../../docs/decisions/0021-draw-the-houses-animations-from-joints.md)).

This README records what the prototype showed and what other tools have done. The decision says what Roga will build and where its code goes.

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

Space plays and pauses, the left and right arrow keys jump 2 seconds back or forward, and the up and down arrow keys change the speed. **Record** plays the replay from the start and saves it as a video.

## What it shows

- The main line runs across the middle. Each branch gets a lane above or below it, nearest first, the way a metro map draws its lines. A lane is free again once its branch has merged, so lanes get reused.
- A branch's line curves off the commit it started from, runs along its lane, and curves back into its merge. The lanes take turns with the graph's eight Monokai colors (decision 27), and the main line is drawn in ink so that the branches stand out.
- A merge into the main line is drawn as an interchange, with a ring in the merged branch's color. A pull request that was squashed onto the main line is drawn as an interchange too.
- Each branch is labeled with its pull request's number and title, and the label fades once it has merged.
- The top shows the date and how many commits, branches and merges have landed so far. The bottom shows the newest commit's hash and subject.
- Stretches where no branch is open, like the first days of this repository, fast-forward. Each commit there flicks its subject off the line on a thin stem, down and up in turn at two heights, and fades within a second, so that something visibly happens at every commit. The few commits right after a merge go without, so that they don't land on the merge's note.
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
- **Squashed and rebased pull requests leave no branch behind.** 766 of the 946 commits on VS Code's main line are squashed pull requests, so most of its work shows as interchanges along a straight line rather than as branches. The replay can't show branches that git doesn't have. For a repository that squashes everything, a lane for each author would say more, since it would still show who did the work when the branches are gone. That's worth trying later.

**A replay needs a length, not a speed.** At a fixed pace, this repository plays for 48 seconds, but two weeks of VS Code would play for seven minutes. The prototype gives quiet stretches a quarter of the time, then speeds the whole replay up to fit 75 seconds, and pulls the camera back to match so that it doesn't pan faster than anyone can read. The labels still crowd when merges come close together, which a real version would need to fix, for example by skipping notes that would overlap.

**Each frame depends only on its time.** The camera follows an average of where the newest commit was over the last half second, rather than easing toward it frame by frame. So playing, scrubbing and recording all draw the same frame for the same moment. This is what makes saving a video simple in the app: it can draw each frame on its own, faster than real time.

## What others have done

Before building the prototype, we looked at what other people have made for showing Git history, and at what spread. Each project's year is when it started. Star counts are from GitHub in November 2026, rounded, and points are from Hacker News. We couldn't find view counts for videos or posts. We left out projects that are archived or no longer change.

- [Gource](https://github.com/acaudwell/Gource) (2009) animates a repository as a tree of its folders and files, with each person as an avatar that flies over to the files they change. It doesn't show branches or merges. It reads the log as a list of who changed which files and when, so it shows where in the code the work happened rather than the shape of the history, which is what the replay is about. It has about 13,000 stars and has reached the front page of Hacker News several times, most recently with 173 points in 2024. What we took from it is how it presents its picture: it skips idle stretches, follows the activity with its camera, glows, and saves video through ffmpeg.
- [Learn Git Branching](https://learngitbranching.js.org) (2012) is a sandbox where the graph rearranges itself smoothly after each command. It has about 34,000 stars and got 717 points in 2013, and it keeps coming back.
- [Git History](https://githistory.xyz) (2019) animates one file through its versions when you swap the domain in a GitHub address. It has about 14,000 stars and got 407 points. Starting it takes no setup at all.
- [git-sim](https://github.com/initialcommit-com/git-sim) (2022) shows what a git command would do, as an image or a video, drawn with the same engine as 3Blue1Brown's videos. It has about 4,700 stars and got 447 points. Its author's git-story, which turns the last few commits into a video, has only about 275 stars, and its author says busy branching with crossing lines looks bad. A clean diagram on its own doesn't spread.
- [GitHub Unwrapped](https://www.githubunwrapped.com) (2021) makes a year-in-review video, with themes and music, to post. It has come back every year since. A crowd of similar year-in-review tools appeared in 2025 without much to show for it.
- [Git City](https://github.com/srizzon/git-city) (2026) turns a GitHub profile into a building in a 3D pixel-art city, with share cards shaped for posts and for phones. It reached about 6,000 stars within months.
- [gitlogue](https://github.com/unhappychoice/gitlogue) (2025) replays commits in a terminal as code being typed. It has about 5,300 stars and got 159 points.
- [GitHub Skyline](https://skyline.github.com) (2020, with a [command-line version](https://github.com/github/gh-skyline) in 2024) turns a year of contributions into a 3D model you can print, and [snk](https://github.com/Platane/snk) (2020) is a snake that eats your contribution graph, as a GIF that keeps itself up to date. snk has about 6,200 stars.
- [MetroGit](https://github.com/vbarbaresi/MetroGit) (2015) draws the Paris Métro as a git graph. It got 262 points when it came out, which says developers like history drawn as a metro map. Mermaid's `gitGraph` draws branches the same way, taking turns with eight colors, as Roga's graph does.

**What the ones that spread have in common**:

- They leave people with one thing to post: a video, an image, a model to print, or something to embed.
- They're about the person's own work.
- Starting them takes almost no effort: one address, one name, or one command.
- A new way of picturing history helps, such as a city, a snake or a metro map, as does music and coming back every year.

**For big or messy histories**, Gource compresses time, skips idle stretches and limits the range, git-story stops at a handful of commits, and the year-in-review tools drop the graph and show totals. We found none that picks out what mattered, such as the ten biggest pull requests.

**What the prototype takes from them**:

- metro-map lanes;
- a camera that follows the newest commit;
- labels that pop in;
- fast-forwarding through quiet stretches;
- a slider to scrub with;
- a last frame that sums the history up, and works as an image to share.

**What it leaves for later**:

- a picture of the files and the people changing them, the way Gource draws a repository, which decision 62 leaves room for;
- avatars;
- a lane for each author, which would help repositories that squash everything;
- themes;
- versions shaped for phones;
- showing the code of a key commit being typed, the way gitlogue does;
- showing what a rebase will do before it runs, which git-sim's reception suggests people want.
