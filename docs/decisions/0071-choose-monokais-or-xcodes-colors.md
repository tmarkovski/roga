# 71. Choose Monokai's or Xcode's colors

Accepted on 2026-11-10. This adds to [decision 27](0027-give-the-graph-and-branches-monokais-colors.md), whose colors become one of two color themes.

## Context

Every color that carries meaning in Roga came from Monokai: the graph's lanes, the branch badges, what was added or removed, the sides of a conflict, the commands in a dialog's terminal block, and the replay's lines. Someone who spends their day in Xcode has a different palette in their eye, and Xcode 27's Standard theme in dark mode, soft pink, salmon, sky, mint and lavender, sits well in a git client too.

Xcode 27 doesn't keep its Standard theme in a file. It builds the theme from a few seed hues in code, and keeps only `{"dark":{"preset":{"_0":"Standard"}}}` in its preferences, so the colors were sampled from its Themes settings. Its swatches are flat fills in Display P3, and several are outside sRGB, so they're kept in P3 rather than clipped.

## Decision

**Settings › Appearance has Colors, with Monokai and Xcode**, under Theme, which still chooses light or dark. Each color theme has colors for both appearances. Roga starts in Monokai, and a choice applies at once to every window.

**A theme colors what carries meaning, and nothing else:**

- The graph's eight lanes, the current branch's badge, its ring and its icon, and other branches' names.
- What was added, removed, and moved or copied, as text and marks, and commits ahead and behind.
- A diff's tints and the bars beside its lines.
- A conflict's sides, and what's unresolved or kept.
- A destructive button's fill, and an agent's green for what works.
- The terminal block's background and the parts of its commands.
- The replay's lines and its counts of what changed, in the window and in a saved video.

The surfaces, text and grays stay Roga's own, as do the orange of what runs something ([decision 19](0019-pull-and-push-from-the-branch-in-the-title-row.md)), an agent's amber and blue, remote branches' and tags' warm gray, and the replay's paper and tiles.

**Xcode's colors take the syntax color nearest each role.** In dark mode:

| Role | Xcode's | Dark | Light |
| --- | --- | --- | --- |
| Lane 1, Pink | Keywords | `#EF89B2` | `#C05E87` |
| Lane 2, Sky | Type declarations | `#5BC7F5` | `#028BB7` |
| Lane 3, Mint | Project types | `#62D6B4` | `#009375` |
| Lane 4, Lavender | Other types | `#CE99F8` | `#9C68C4` |
| Lane 5, Gold | Numbers | `#E1AB3A` | `#A47916` |
| Lane 6, Blue | Links | `#6896E0` | `#5380C9` |
| Lane 7, Magenta | Other members | `#C85BDF` | `#BB4ED2` |
| Lane 8, Slate | Comments | `#ACB3CB` | `#798096` |
| Current branch, added | Source Control's additions | `#65DB80` | `#008939` |
| Removed | Source Control's deletions | `#F09283` | `#B2594D` |
| Other branches, moved | Type declarations | `#5BC7F5` | `#117EA5` |

All are Display P3. Light mode has each darkened in OKLCH, keeping its hue, until a lane clears 3:1 on a row and on a selected row, and text clears 4.5:1, which is the bar decision 27 set. Xcode's light theme wasn't used, because its colors are much darker than its dark theme's and would make the two appearances look like two themes.

**Monokai's colors don't change**, including a diff's tints, which stay the system's green and red as decision 27 left them. Xcode's diff takes its own additions and deletions.

**In the terminal block, a dangerous option is a red of its own**, `#FF6B66`. Xcode's deletions are the same salmon as its strings, which color a commit's message, so the two would read alike.

## Consequences

- The name says where the colors come from, not what they look like. "Dracula" was suggested, but Dracula is a theme of its own with different colors.
- AppKit views keep colors that follow the theme each time they're drawn, so changing it only asks every view to draw again, and calls `viewDidChangeEffectiveAppearance()` for the few that keep a color in a layer. SwiftUI views read the theme in their bodies, which draws them again when it changes.
- Another theme is a value in `ThemeUI`'s `ThemeColors` and a case of `ColorTheme`. The tests check each theme's contrast in both appearances, so a theme that doesn't read can't be added quietly.
- In light mode, Monokai's diff bars are still about 2.2:1 on white, as decision 27 noted.
