# 36. A solid ink tile for what's selected on the rail

Accepted on 2026-11-04. This makes the rail the one exception to what the [main window](../main-window.md) says about selection, which is that it's a soft gray fill. The list and everything else keep the gray.

## Context

The rail marked the selected item with a gray square behind a white tile, and marked an item under the pointer with almost the same gray square. We worked out the contrast from the app's colors, using the grays the design canvas draws the sidebar with, since the real one is a system material. The selected gray was about 1.24:1 against the rail in light and 1.31:1 in dark, and only 1.07:1 and 1.10:1 against hover. In dark mode the selected tile was darker than the others. Which organization you were in came down mostly to the other items looking dimmer, and that wasn't enough to find it at a glance.

We drew five options on the design canvas, on its Rail selection page: the tile filled with the brand's orange, the system accent or ink, and a ring around it in ink or the system accent.

## Decision

**The selected item is a solid tile in ink.** It's 28 points square, the same size and shape as an organization's tile, with the letters or the icon in white, or in near-black in dark mode. The ink is what dialogs use for their main button and their switches, so `Palette` now holds it and `DialogColors` refers to it. All and Other have no tile of their own, so they get one while they're selected.

**The selected item doesn't react to the pointer.** The gray square under the pointer is only for the items you could still switch to.

**The add button keeps its gray square while its popover is open.** That isn't a selection, so it shouldn't look like one, and VoiceOver no longer calls it selected.

**Nothing else changes.** The items that aren't selected look as they did. Rows in the list keep the soft gray, because they need to stay quiet in a long list, whereas something on the rail is always selected and it says which part of your work you're looking at.

**Why not orange.** Orange already means uncommitted files in this same sidebar and a count that a click would run in the title row. A tile that's always lit sits right beside those counts and takes the eye away from them.

**Why not the system accent.** Roga doesn't use it anywhere else, and the graph and the branches deliberately don't follow it ([decision 27](0027-give-the-graph-and-branches-monokais-colors.md)). White letters are also only about 4:1 on the default blue, which is low at 11 points, and someone whose accent is orange would get the same clash as above.

**Why not a ring.** A ring in the system accent looks just like keyboard focus, which macOS draws around a button when keyboard navigation is on, so the selected item and the focused one couldn't be told apart. A ring in ink avoids that and was the second choice, but it's thinner than a fill, and All and Other end up with a ring around a bare icon.

This is the same reasoning as the current branch's solid badge in [decision 23](0023-one-badge-for-a-branch-and-its-upstream.md): a solid shape is a different thing on the page, and not just a different shade, so it doesn't rely on seeing color.

## Consequences

- Measured in the running app, the selected item is about 15:1 against the rail in light and 12.6:1 in dark, and the letters are about 15:1 or better on the tile.
- Having no hue, it doesn't compete with the orange counts or the green badge. It also leaves color free for the marks that [decision 16](0016-a-rail-of-organizations-in-the-sidebar.md) left room for once Roga knows what agents are doing, though those aren't designed yet.
- It gives up the brand's color on the rail, and in dark mode the tile is the brightest small thing in the sidebar. If that turns out to be too much, the ring in ink is the option to go back to.
- It looks the same when the window is in the background, as the gray did.
- The main window's rule about selection now has an exception, which it says.
