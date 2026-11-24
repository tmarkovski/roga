# Setup lane

Boards for drawing setup's floor as one lane of a commit graph, in history's style, with a commit for each screen. They're on the Setup lane page of the design canvas [yaga layout options](https://claude.ai/artifact/4WQVua6gwKqSBoiRdf2FhX#page-setuplane), and [`boards.py`](boards.py) draws every board, borrowing the house from [`../settings/boards.py`](../settings/boards.py).

The idea came from a review of setup on November 24, 2026. Today the dots at the top of the window say how far along setup is, and the house runs along a hairline floor at the bottom ([decision 69](../../decisions/0069-set-roga-up-in-the-whole-window-the-first-time-it-runs.md)). As a lane, the floor says both, and names the steps: each commit's subject is that screen's small title above its heading, reworded to read as a commit subject.

| Screen | Small title today | As a commit |
| --- | --- | --- |
| Welcome | none | Initial commit |
| Looking | Your Mac | Look around |
| Git | Git | Choose git |
| Agents | Agents | Add agents |
| Hooks | Hooks | Install hooks |
| Ready | Ready | Open Roga |

The page draws today's Git screen, two options on it, A on every screen and with no agents, a done commit under the pointer, and A in the dark appearance.

- **A** puts every commit's subject under it, ink for HEAD, the note gray for what's done and the faintest gray for what's to come.
- **B** names only HEAD, in a badge like history's current branch, and leaves the rest as dots.

In both, done commits are solid, HEAD has history's green ring with the house standing on it, and later commits are hollow, past a faint line. A done commit is a button that goes back to its screen, as Back does. The dots at the top go, and the screens keep their small titles in orange above their headings, in the new words.

## Regenerating the boards

Read `project/canvas.json` from the canvas into a folder first, so that the merge starts from what's live, then:

```bash
uv run docs/design/setup-lane/boards.py --out <folder> --canvas <folder>/project/canvas.json
```

It writes the `Sn-*.dc.html` boards into `<folder>/project/` and replaces the Setup lane page's boards and notes in that `canvas.json`, leaving every other page alone.

## Built

A was built on November 24, 2026, with a bypass for skipped steps, as [decision 69](../../decisions/0069-set-roga-up-in-the-whole-window-the-first-time-it-runs.md) now says, in [`SetupLane.swift`](../../../RogaKit/Sources/RogaUI/Setup/SetupLane.swift). Where the app differs from the boards:

- **The lane is pinned along the bottom of the window,** under every screen after Welcome, and a screen too tall for the window scrolls above it and fades out where it meets it. The boards draw the lane where the floor was, which dropped out on a screen with no room for it, and with the dots gone that would have left the Hooks screen with nothing to say how far along setup is.
- **The lane takes history's first lane color from the theme chosen in Settings,** as history does, rather than Monokai's always.
- **A step answered No is skipped, not taken off the lane.** Don't Use Agents, and finding no agents, skip Add agents and Install hooks, and Not Now on Hooks skips Install hooks. A bypass goes around them and the house hops over them, as the Steps answered No boards draw it.
