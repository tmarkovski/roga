# 64. Dress the replay as a departure board, and end it on a poster

Accepted on 2026-11-08, and built the same day. This replaces how [decision 62](0062-replay-a-repositorys-history.md) shows the numbers at the top and how a replay ends, and adds the house that decision 62 left out. Everything else about the replay stays as decision 62 has it.

## Context

The numbers in the first version were small and all one size, so nothing said which of them mattered, and the picture had no frame to give it any weight. The zoom out at the end worked, but it left the eye nothing to land on, and the last frame, which is what Save Image writes, was a thin map with a line of text over it.

We tried this in the design canvas first, on the Replay page, with four ways to frame the numbers, four endings, and a list of things that could happen along the way, drawn from this repository's real history. The choices are written under the boards there.

## Decision

**The numbers go on a departure board.** A band across the top is ruled into cells: the repository and branch, then which day of how many it is with the date, then lines added, lines removed, commits, branches and merges. Each digit has its own split tile, and a changed digit rolls inside its tile, the way decision 62 rolls them. Every tile shows from the start, so a number's row never changes size. The tiles are the largest of three sizes that fit the window, and they're chosen from each number's last count, so the size doesn't change during a replay. A window too narrow for the smallest tiles gets the band with the numbers on a line under the date, as decision 62 had it.

**A strip across the bottom says what's arriving**: the commit's color, its hash, the lines it changed, its subject, and which branch it's on.

**Under the band, a pulse shows how much every commit changed**, green above a line and red below it, filling in as the replay plays. Each bar sits at the same place across as its commit does once the camera has pulled back, so the two line up at the end. A long history is gathered into at most 480 bars. A window shorter than 500 points leaves the pulse out, to keep room for the map.

**A commit's stop is as big as the commit.** Size goes with the logarithm of the lines it changed. Once the camera has pulled back, only the really big commits stay big, or the stops would run together.

**Things happen on the map.**

- The biggest commits' lines fly up into the count of lines added, for the sixteen biggest that changed more than 900 lines.
- When a new day starts, a line sweeps down the picture and the day's name comes up beside it. These thin out when days go by too quickly to read.
- Records get a card and two rings as they land: the biggest commit, the latest night, the longest branch, the busiest day, and the 100th commit and each power of ten after it. When two would come up within 2.6 seconds of each other, only the first in that list does.

**The ending has three parts.** The camera pulls back, as before. Then a tour turns the map down and stops for two seconds at each thing that stood out, bringing back just that stop, day or branch, with a card about it. Then the map moves up, the band and the strip fade, and a poster comes in: a title with the totals, and tiles for the busiest day, the biggest commit, the longest branch and when in the day the work happened. The poster is the last frame, so it's what Save Image writes and what someone who asked for less motion sees.

**Only what stands out is pointed out.** A replay of one day has no busiest day, a commit made at 6 in the evening isn't a late night, a branch of one commit isn't the longest of anything, and a replay of fewer than twelve commits has no tour. A window too small for the tiles shows the title and the map alone. Working these out is `HistoryReplay.highlights(in:)`, in `CommitGraph`, which doesn't use AppKit and is tested on its own.

**The house can walk the line, and starts off.** A button with the house on it, in the row under the picture, turns it on or off, and the setting stays as it was left. It's the house from [decision 21](0021-draw-the-houses-animations-from-joints.md), drawn from its joints in the pushing stride. It stays with the camera so that the line slides along under its feet, and glides between lanes to stay with the newest commit. Keeping it on the main line left it walking on nothing while commits landed on a branch. It steps in time with the picture, so a frame still depends only on its time.

**Top contributors stay out for now.** In a repository with one author, a leaderboard says nothing, and in this one 200 of 202 commits have the same name on them. It needs reading each commit's author, and a rule for when there are enough people for it to mean something.

## Consequences

- The ending takes about 15 seconds rather than 5, so a replay of 45 seconds saves as a video of a minute. The tour is the thing to shorten if that turns out too long.
- Lines are counted after the replay starts, so the biggest commit joins the tour once they're in, and the tour gets two seconds longer. The player keeps the same moment when that happens, rather than the same fraction of the way through.
- Lines arriving also adds two cells to the band, which moves the date to the left once. Decision 62 kept everything still when they came in, but the band can't, since it doesn't know how many tiles they'll need until they're counted. It usually happens before the first commit lands.
- A frame takes 3 to 4 ms to draw at 1920 by 1080, in a debug build.
- A frame in the tour draws the map twice, since what it stops at goes back over the dimmed map at full strength.
