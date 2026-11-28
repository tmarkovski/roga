# 125. Give the refs panel's sections the headings the uncommitted files have

Accepted on 2026-11-28. This puts counts back on the refs panel's section headers, which [decision 84](0084-headers-show-no-counts.md) took off, and puts the commands on those headers in words. It also gives line counts the font's own digits everywhere, in place of digits of one width. The sidebar's header for its list keeps its count in its tooltip, as decision 84 says. The button that deletes merged branches is still the one [decision 119](0119-branches-on-one-line-and-what-the-pointer-lights-up.md) added, in words now.

## Context

The refs panel and the panel for uncommitted changes both have lists under headings that stay in view, and they looked as if they came from two apps. The refs panel's headings were gray titles 28 points tall with a chevron after them, nothing between one section and the one above it, and an icon at the right for a command: a + on Remotes, and on Branches a button that deletes the merged branches. The headings over uncommitted files have their title in the text's own color, how many files there are in gray, and their buttons in words, **Discard All…** in red and **Stage All**, which turn into icons in a narrow panel.

In the refs panel, a section's last rows ran straight into the next section's gray title, so in a long list it was hard to see where one section ended. The two icons said what they did only in their tooltips.

Decision 84 took the counts off because a gray number beside a title looked like the numbers that ask for something, such as commits to pull. Since then, [decision 115](0115-one-scroll-for-a-worktrees-files-with-headings-that-stay-in-view.md) has kept a count right after the title of every heading over uncommitted files, so that's the place the window already uses for how many there are. Taking the count off also left a collapsed section with no way to say how big it is until the pointer rested on it.

## Decision

**A section's heading looks like a heading over uncommitted files.** Its title is no longer gray, at 12 points and medium weight, and after it come how many the section has, in gray, and then the chevron. It's 32 points tall, with 6 points above and below its 20-point title. A section with nothing in it shows neither a count nor a chevron.

**A line parts each section from the one above it.** The first section has none, because the panel's header ends in a line right above it. While a heading is held at the top with its rows scrolling under it, the line moves to its bottom, as it does on a stuck heading over uncommitted files. A heading still stays at the top only while its own rows scroll, and the next section's heading pushes it away. The headings don't stack at the top and the bottom as the ones over uncommitted files do, because those rely on every row being one height to know where they go, which the refs panel's rows aren't, and five stacked headings would take 160 points of a short panel.

**A section's command is in words while there's room**, in the same buttons as Discard All… and Stage All: **Add Remote…** on Remotes, and **Delete Merged…** in red on Branches while there are merged branches to delete. The tooltip of Delete Merged… still says how many, as in `Delete 8 merged branches…`. In a panel too narrow for the words, each turns back into its icon. The words end on the line where the rows' labels end.

**Clicking a heading still collapses or expands its section.** VoiceOver says how many in words, as in `12 branches, Expanded`. The tooltip that had the count is gone, since the heading shows it.

**Line counts use the font's own digits**, on headings and on rows alike, rather than digits of one width. On a heading such as **Unstaged 14 +644 −346**, the count of files had the font's own digits and the line counts had digits of one width, so the numbers looked like two sizes of type, though all of them are 12 points. A submodule's label, which takes the line counts' place on its row, uses the font's own digits too.

## Consequences

- A collapsed section says how big it is.
- The two panels' headings read the same way: the title, how many, and at the right what the heading can do.
- The count on Remotes is how many remotes there are, not how many of their branches the section lists.
- A heading is 4 points taller than before, so a full panel shows a little less.
- In a list of files, the line counts' digits no longer line up from one row to the next, and a count gets a little wider or narrower as it changes, such as while an agent edits a file.
- The sidebar's **Repositories** header keeps its count in its tooltip, as decision 84 has it.
- The panel for uncommitted changes is unchanged, and its lists still can't be collapsed.
