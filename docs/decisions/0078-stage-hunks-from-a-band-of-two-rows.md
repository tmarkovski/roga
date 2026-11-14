# 78. Stage and unstage hunks from a band of two rows

Accepted on 2026-11-14. This brings staging by hunk forward from release 2, and changes how [decision 39](0039-discard-with-undo-and-ask-only-for-many.md) drew a hunk's band and its button.

## Context

A hunk could be discarded from its band, but not staged, so taking part of an agent's change into a commit meant going to the command line.

The band was one row of the diff, tinted blue across the full width, with git's `@@` line as its text. Every row of a diff is the same height, which is how a position in the view becomes a row without asking TextKit for layout ([decision 9](0009-diff-view-uses-textkit-1.md)). So a button on the band had to be 15 points tall, smaller than any other button in Roga, and it kept a background and a border because it could sit over the header's text. Hunks also ran straight into each other, with only the tint between one and the next.

We drew four bands to compare: today's, today's with a bottom border and no tint, a tinted band two rows tall like a conflict's ([decision 60](0060-resolve-conflicts-in-the-diff-panel.md)), and a gap above a quiet band two rows tall with a line under it. We chose the last, with buttons that are only their words.

## Decision

**A hunk's band is two rows.** Its rows are empty in the text, as a conflict's band's are, and still say they're the header's, so nothing takes them for lines of the file. The layout manager draws the band: about a quarter of it is a gap above, 8 points in the usual code font, then git's header in gray, centered in what's left, over a line as wide as the view, which runs on under the line numbers. There's no fill. The gap gives way in the smallest code fonts, so that a button of the usual size still fits.

**Its buttons are the usual small size and only their words.** They're 22 points tall, with no border, and fill with gray while the pointer is on them, as the words beside a file's path in the diff panel's header do. At rest they're filled with the panel's own color, which looks like nothing, so a long header doesn't show through them. They still show only while the pointer is in the hunk.

**Stage Hunk and Unstage Hunk.** In an unstaged diff the band has Discard Hunk, in red, then Stage Hunk at the edge, the order a file's row has. In a staged diff it has Unstage Hunk. Right-clicking a hunk offers the same, with discarding last. Staging or unstaging a file's last hunk moves the file to the other list, as its row's button does.

| What moves | How |
| --- | --- |
| A hunk into the index | `git apply --cached` |
| A hunk out of the index | `git apply --cached --reverse` |

**The hunk is placed on the side it goes to.** Decision 39 rewrites a hunk's header so that both sides say where its lines are in the file on disk, the new side of an unstaged diff. Staging applies it to the index, which is the old side, so there both sides say where the lines are in the index. Unstaging takes it out of the index, which is the new side of a staged diff, as discarding does from the file. git looks first where the header says and takes the first place that matches, and another copy of the same lines can be there.

**The commands name a hunk by its header's place in the patch,** not by its band's row, which is further down by a row for each band above it.

## Consequences

- Hunks take a row more each, so a diff of many small hunks is a little longer.
- Copying lines across two hunks copies an empty line or two where the band is, rather than git's `@@` line. Find in Diff doesn't look in the header.
- The diff panel's header has Discard File, or Move to Trash for an untracked file, before Stage File, and the uncommitted changes panel's header lost its button for discarding everything, because each list's heading has Discard All… right under it.
- Staging by line is still in release 2.
