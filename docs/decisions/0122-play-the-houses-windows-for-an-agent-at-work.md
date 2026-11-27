# 122. Play the house's windows for an agent at work

Accepted on 2026-11-27. Partly supersedes [decision 46](0046-turn-the-ring-of-an-agent-at-work.md): an agent at work is marked by the four windows of Roga's house, playing one of the window animations, where decision 46 turned a ring. How it's played, in Core Animation, in step and only while it can be seen, still holds, and so does the rest of [decision 41](0041-agents-status-from-their-hooks-and-messages-from-their-clis.md)'s marks.

## Context

The ring was a generic spinner. Roga now has six short animations made from the four panes of the house's window, `HouseWindowAnimation`: Window Chase, Shutter Flip, Sash Shift, Lantern Sweep, Double Tap and Stack and Deal. They say "busy" in Roga's own shapes and colors, and they were made for marks this small.

`HouseWindowAnimationView` draws them in SwiftUI, working out each frame on Roga's main thread. That's fine for a few seconds, and it's the cost decision 46 moved the ring away from, because an agent can work for hours and a sidebar can show several at once.

## Decision

**The working mark is the house's windows, upright, playing one animation.** Everywhere the ring was, the windows are: the sidebar's rows, a worktree's tab, the branch row's popover, the commit box's Stop button, the strip above a conflicted file, setup's rows while it looks for programs, and the legends in Settings. The ring that Run a Test turned on an agent's page in Settings is the windows too, since it waits for an agent.

**Each launch picks a different animation.** Roga picks one as it launches, at random from the five that the last launch didn't show, and every mark shows that one until Roga quits. It keeps the name of its pick in its defaults, under `agentWorkingAnimation`, for the next launch to avoid.

**Core Animation plays it, as it turned the ring.** `HouseWindowLayerView` draws each pane as a shape layer and the band of light as a gradient masked to the window. The poses come from the animation itself, sampled 60 times a second over one loop, and Core Animation plays them as keyframes in the render server, so neither SwiftUI nor Roga's main thread does anything for each frame. Properties that don't change in an animation get no keyframes. As with the ring:

- **Every mark is at the same pose at the same moment,** whenever its agent started, because each starts as far into a loop as the clock is.
- **It stops whenever its window can't be seen,** as `NSWindow.occlusionState` says, and starts again once the window can be.
- **It stands still for someone who asked for less motion,** on each animation's still frame.

**The windows stand upright, not at the logo's 11° tilt.** We drew every animation both ways at the sidebar's sizes. Upright, the four panes still look like the house's window, and they sit better among the row's words and its other marks, which are all upright. The animations turn with the window, so Sash Shift slides the panes straight across and the band of light keeps its angle to them.

**The panes at rest are three quarters of the mark's box across,** a little narrower than the ring's 13/16, because solid panes in a square look bigger than a circle drawn with a line. That keeps them about as big as the waiting circle beside them. Sash Shift slides the panes out sideways, so for a moment they reach about half a point past a 14-point box. Clicks and the pointer still pass through to the row.

## Consequences

- The keyframes for an animation, at one size and in one appearance, are worked out once and shared by every mark. That's about 100 to 170 poses for each pane, depending on how long the animation is.
- The render server draws four small panes, sometimes with a glow, where it drew two strokes for the ring. Nobody has measured WindowServer with several agents at work yet, as decision 46 did for the ring.
- Tests keep the layers and `HouseWindowAnimationView`'s canvas from drifting apart. One draws each animation's still frame both ways, tilted and upright, in both appearances, and checks that the pixels agree. Another stops Core Animation's clock at moments all through each loop and checks that the panes' movement, colors and glow, and the band of light, are where the canvas puts them.
- The canvas still draws the ring.
