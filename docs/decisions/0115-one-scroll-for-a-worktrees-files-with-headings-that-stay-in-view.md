# 115. One scroll for a worktree's files, with headings that stay in view

Accepted on 2026-11-26. Partly supersedes [decision 55](0055-split-the-panel-for-uncommitted-changes-40-40-and-20.md), which gave the files still to stage and the staged files a list each, 40% of the panel apiece, and the part of [decision 30](0030-stage-and-commit-beside-history.md) that keeps the staged files in view right above the message. The message box still takes a fifth of the panel, or what it needs, as decision 55 says, and a list with no files still isn't shown, as [decision 61](0061-hide-a-list-with-no-files.md) says.

## Context

Decision 55 split the panel for uncommitted changes into two lists with a scroll each: Conflicts, Unstaged and Untracked above, and Staged below, right over the message. Each list had to scroll on its own. A long list of untracked files scrolled inside its 40% while a few staged files sat in a mostly empty 40% under it, and going through the files with the arrow keys went from one scroll to the other at the line between them. The lists are one set of files, read from top to bottom, and two scrolls made them feel like two places.

Putting everything in one scroll would lose what the split gave: the staged files, and the buttons on their heading, always in view.

## Decision

**Conflicts, Unstaged, Untracked and Staged are one list in one scroll,** in that order, above the message.

**A list's heading stays in view while its files are scrolled away.** It stays at the top while its files scroll under it, and once they're gone it stays there, under the headings of the lists before it. The heading of a list whose files are all below the view stays at the bottom, over the message and over the headings of the lists after it. So every list with files has its title, its count and its buttons in view however far the files are scrolled. While a heading is stuck at an edge, a line parts it from the files that go under it, and clicking it anywhere but on its buttons scrolls to its files, with its first file right under it.

**Moving through the files with the arrow keys scrolls only as far as it takes** to keep the selected file clear of the headings stuck at the edges.

When a filter leaves no files in any list, one note says so, where each list used to say it in its own room. In a panel too short for every heading, the ones at the top keep their places, and what doesn't fit is cut off at the message box.

## Consequences

- A long list of files to stage gets the whole height above the message, rather than 40% of the panel.
- The staged files aren't always in view any more, but Staged's heading is, with how many there are, how many lines they change and Unstage All. Seeing one staged file takes scrolling to it or clicking the heading.
- Staging a file takes its row out of its list and puts it in Staged, and the rows after it move up one, as they did within a list. There's no line between two lists for staging to move.
- With every list's files scrolled away, the headings take 36 points each at the edges, so four of them take 144 points of the scroll.
- The lists no longer glide to new heights when one comes or goes, since they share one scroll. The message box still glides when Amend changes what it needs.
- Each list's rows are still in a lazy stack of rows that are all the same height. Where a heading sits follows from where its list's rows start, which a model of their own holds, and only the headings read it, so scrolling draws nothing else again.
