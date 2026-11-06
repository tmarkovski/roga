# 42. Run each line down to its parent, in its lane's color

Accepted on 2026-11-06. Partly supersedes [decision 27](0027-give-the-graph-and-branches-monokais-colors.md): the graph keeps Monokai's colors, but each lane has one rather than each column. It also settles a question that [ARCHITECTURE.md](../../ARCHITECTURE.md) kept open, whether the lanes' colors should follow branches rather than columns.

## Context

Two lanes that waited for the same commit joined as soon as they met, into the one on the left. A branch's last commit sent its line into the main line's column above the commit they both led to, and a lane could move into a commit's column in that commit's own row. That kept the graph narrow, but a line could end above its parent, or sweep past a dot it had nothing to do with. In Roga's own history, the line from tm/agents' last commit moved into the first column in the row of the commit `HEAD` was on. It met the ring around that dot and seemed to end there, though its parent was the next commit down.

Each column had a color, and a line took the color of the column it went into. So a line that moved over changed color for the bend, and kept the new color after it. The line from tm/agents' merge of `main` ran green for ten rows, then turned pink where it moved into the first column, beside the pink dot of a merge it had nothing to do with.

Fork draws the same history with each line in its own column until its parent's row, coming into the parent's dot from the right, and in one color from end to end. It takes a column more there.

## Decision

**A line runs down its own column to its parent's row, and comes into the parent's dot from the right.** A commit takes the leftmost lane that waits for it, and the other lanes that wait for it end at its dot. Their lines arrive sideways, the curve that the line from the uncommitted row into `HEAD` already used. A commit's first parent keeps its lane, and every other parent gets a new one, even when another lane already waits for that commit. Lanes still step left, one column a row, into a column that frees up, so the main line stays in the first column.

**A lane keeps its color.** It gets one when it starts: its column's, in turn, unless a lane beside it already has that color, and then the next one that neither has. It keeps that color when it steps left, and a line that ends at a dot keeps it right up to the dot. A dot has its lane's color. A line cut for being too long starts again above its parent in the color it was cut in, and the line from the uncommitted row has the color of the column it starts in.

**Colors follow lanes, not branch names.** A lane is a line of first parents, which is what the eye follows, so it's what keeps a color. Giving `main` one color everywhere would mean deciding which lane a branch is when several lead to it.

## Consequences

- The graph is wider where lines used to join early. On Linux in topological order, which history uses by default, half the rows still need 2 columns and 90% still need 4, but 99% need 9 rather than 7, and 99.9% need 14 rather than 12. In date order, 99% need 15 rather than 12. The 10 columns a row shows still hold 99% of rows in topological order.
- Laying out all of Linux in the background takes about 0.65 seconds in topological order rather than 0.5, and 0.8 seconds in date order rather than 0.7. The first screen's layout is unchanged, at about half a millisecond.
- A graph whose lanes never move looks as it did, because a lane starts with its column's color. One whose lanes step left keeps each line in one color, so the first column isn't always pink: when history's first row is on a branch, the main line starts in the second column, in sky, and stays sky once it moves into the first.
- The layout stores a color for each row and each line that changes column, and the colors of the lines crossing into every 64th row, as well as a byte for each commit, which says whether more than one lane waits for it and whether a far child's line was cut on its way there.
- A test follows every line in the test repositories, checks that it keeps its color from one row to the next, and checks that a line ending at a dot comes from above it or from its right.
