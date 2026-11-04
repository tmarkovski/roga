# 27. Give the graph and the branches Monokai's colors

Accepted on 2026-11-04.

## Context

The graph took its colors from the system: the accent color, then purple, teal, orange, pink, green, indigo and brown. The current branch's badge had its own bright green. Together they looked neon, they had nothing to do with the mark, and the green read as lime.

They were also weak in light mode. A line 1.5 points wide needs about 3:1 against what's behind it, and the system's green is 2.2:1 on white and 1.8:1 on a selected row.

We compared palettes on one page, each with the same history at real size, in dark and light: six drawn from old books, one from a reference of coral, golden, yellow green, steel blue and grape, three playful variations on that, and Monokai.

## Decision

**The colors are Monokai's.** Each column of the graph has one, in turn:

| Column | Name | Dark | Light |
| --- | --- | --- | --- |
| 1 | Pink | `#FF3478` | `#DB1C61` |
| 2 | Sky | `#66D9EF` | `#10819E` |
| 3 | Green | `#A6E22E` | `#608A00` |
| 4 | Violet | `#AE81FF` | `#7240C0` |
| 5 | Yellow | `#E6DB74` | `#968505` |
| 6 | Blue | `#6796E6` | `#2552AA` |
| 7 | Stone | `#A59F85` | `#676450` |
| 8 | Seafoam | `#A1EFE4` | `#0D906D` |

**Dark mode uses Monokai's own values where it can, and accessibility comes first.** Its pink, `#F92672`, is lifted slightly so that it clears 3:1 on a selected row. Classic Monokai has no light theme, so light mode has a deeper version of each color.

**Monokai's orange is left out**, because orange means a click would run something ([decision 19](0019-pull-and-push-from-the-branch-in-the-title-row.md)). Blue, stone and seafoam, from around the Monokai family, bring the columns to eight.

**The current branch has one color everywhere:** `#A6E22E` in dark and `#547A02` in light. That's its badge's fill, the ring around the commit `HEAD` is on, and its icon in the refs panel. The dot inside the ring keeps its column's color, because it's still part of that line.

**The current branch's badge loses its checkmark.** [Decision 23](0023-one-badge-for-a-branch-and-its-upstream.md) has it filled, with a checkmark, but the checkmark was always paired with the fill, the ring and the bold subject, so it added nothing they didn't already say. Without color, the badge is still filled where the others are outlined, and VoiceOver and its tooltip still say it's the current branch. The refs panel keeps its check, because that row has no fill and its icon's color would otherwise be the only sign.

**The rest follows from the same family.** Other local branches' names are sky. What was added, and commits ahead, are green. What was removed, and commits behind, are pink. What was moved or copied is sky. Remote branches and tags stay a warm gray ([decision 23](0023-one-badge-for-a-branch-and-its-upstream.md)).

## Consequences

- The first column doesn't follow the macOS accent color any more, and neither do the other colors here.
- `#A6E22E` is yellower than the green it replaces, which read as lime too, with a hue of about 130 rather than 148. We chose it knowingly, because Monokai doesn't look like itself without it. Monokai Pro's softer `#A9DC76` would be the change to make if it grates.
- Light mode carries less of Monokai's character than dark mode does, and its green turns olive.
- Surfaces stay neutral, at `#222222` in dark. Monokai's own olive-black, `#272822`, is only the text on the current branch's badge.
- A diff's backgrounds and bars, a changed file's orange and the sidebar's counts still use system colors. In light mode, the system's orange has the same weakness on white as its green did.
- A test checks that every column clears 3:1 on a row and on a selected row in both appearances, and that text in these colors clears 4.5:1, so that a later change to a color can't quietly lose that.
