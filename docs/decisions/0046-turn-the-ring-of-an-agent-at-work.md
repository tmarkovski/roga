# 46. Turn the ring of an agent at work

Accepted on 2026-11-06. Partly supersedes [decision 41](0041-agents-status-from-their-hooks-and-messages-from-their-clis.md): the ring that marks an agent at work turns, where decision 41 had it stand still. The rest of decision 41 still holds.

## Context

Decision 41 drew the ring still, as the design canvas does, because a spinning mark on every row would keep the sidebar redrawing. But a gray ring with an orange quarter that never moves reads as a progress indicator stuck at a quarter, so it didn't plainly say that an agent was doing something ([issue 17](https://github.com/tmarkovski/yaga/issues/17)).

The cost decision 41 worried about comes from turning the ring in SwiftUI. A `.rotationEffect` with a repeating animation has SwiftUI work out a new frame on Roga's main thread many times a second, for as long as any agent works, which can be hours. Core Animation can play a repeating animation in the render server instead, which on the Mac is WindowServer, so Roga itself does nothing for each frame.

## Decision

**The orange quarter turns clockwise, once a second, and Core Animation turns it.** `AgentRingView`, a layer-backed view that SwiftUI hosts, draws the canvas's ring as two shape layers, and a `CABasicAnimation` on the arc's `transform.rotation.z` repeats forever. Clicks and the pointer pass through it to the row, as they did when SwiftUI drew the ring.

- **Every ring is at the same angle at the same moment,** whenever its agent started, because each starts as far into a turn as the clock is. A sidebar with several agents at work turns as one, rather than as a scatter of spinners.
- **It stops whenever its window can't be seen:** minimized, hidden, on another Space or fully covered, as `NSWindow.occlusionState` says. Stopping takes the animation away, so WindowServer has nothing to draw, and it starts again once the window can be seen.
- **It stands still for someone who asked for less motion,** as the house does.
- **The legends turn too.** The legend on the Agents page and the list of events on each agent's page draw the same mark, so the key looks like the sidebar it explains.

## Consequences

- Roga's own process does no more work while rings turn. With five agents working in a test copy, a Release build on an M1 Max, the still ring and the turning ring each came to under 0.07% of one core, 0.1 to 0.2 wakeups a second and under half a milliwatt, in two rounds of each, with no difference between them beyond noise.
- WindowServer draws the frames, so the cost shows on its row in Activity Monitor rather than Roga's. While a window with turning rings could be seen, WindowServer used about 3.6 points more of one core than while the same window was covered, averaged over three runs that ranged from 1.5 to 5.1, on a 60 Hz Studio Display. The same comparison with the still ring showed no difference. Asking Core Animation for 30 frames a second rather than 60 didn't lower it measurably, so the ring doesn't ask.
- `ImageRenderer` draws nothing for an `NSView`, so it can't draw the ring into an image. Tests draw marks with `cacheDisplay` from a window that's never shown.
- The canvas still draws the ring still.
