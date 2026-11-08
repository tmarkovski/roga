# 55. Split the panel for uncommitted changes 40, 40 and 20

Accepted on 2026-11-07. Partly superseded by [decision 60](0060-hide-a-list-with-no-files.md), which hides a list with no files rather than keeping its heading. This changes [decision 30](0030-stage-and-commit-beside-history.md), whose Staged list took up to 45% of the lists' room before it scrolled, and whose message box was only as tall as its text. The rest of decision 30 still holds.

## Context

Decision 30 sized the Staged list by its rows, up to 45% of the room the lists had, and gave the list of files to stage whatever was left. So the line between the two lists moved every time a file was staged or unstaged. Going through an agent's change one file at a time with Space, the rows kept shifting under the pointer. With nothing staged, the Staged list wasn't there at all, so staging the first file brought it in from nowhere. With everything staged, the list over it was an empty space as tall as whatever Staged didn't take. In a maximized panel, the message box stayed three lines tall under a lot of empty room.

We considered three ways to handle a list with no files. Giving it a fixed 20% or 15% keeps the line still, but leaves that much of the panel blank. Hiding it entirely gives the other list all the room, but brings Staged in from nowhere again when the first file is staged.

## Decision

**The files to stage, the staged files and the message split the panel's height 40, 40 and 20.** Conflicts, Unstaged and Untracked share the upper list as before. The lists' heights depend on whether they have files rather than on how many, so staging a file moves only its row.

**A list with no files keeps only its heading,** which says 0 and has no buttons, and the other list takes its room. The heading still says where files will go, and it costs one row rather than a fifth of the panel. The heights follow the files themselves rather than what a filter matches, so typing in the filter doesn't move the line. A list whose files don't match the filter says so in its own room.

**The message box gets a fifth of the panel, or what it needs if that's more.** Its text fills the room it's given. It never gets shorter than its heading, three lines of text and the Commit button, which come to 146 points, so a fifth is more than that only in a panel taller than about 730 points. At the split's usual height, the box stays at its least and the lists share the rest evenly. A maximized panel gets 40, 40 and 20. A message longer than the box still grows it, up to 240 points of text, and the two lists give up that room equally.

**Two layouts of Roga's own place the three parts** (`ChangesSplit`), rather than frames sized from a height measured after the fact. A list's height then follows a change in the box's height in the same pass, with no frame in between where they overlap.

## Consequences

- While both lists have files, staging and unstaging move rows but not the line between the lists. Staging the first file or unstaging the last one still moves it, between a heading and 40%.
- With a few staged files, Staged has more empty room under them than before, and the list over it has less, so a long list of unstaged files starts scrolling sooner.
- In a maximized panel, the message box is taller than three lines, which leaves room to write a longer message before the box grows.
- A heading with no files has no buttons, and VoiceOver finds no actions on it.
