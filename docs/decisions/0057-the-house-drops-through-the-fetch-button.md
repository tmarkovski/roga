# 57. The house drops through the Fetch button

Accepted on 2026-11-07. This replaces how the Fetch button shows a running fetch in [decision 45](0045-fetch-and-new-branch-as-buttons-and-the-commit-count-with-history.md), where its icon turned. Everything else about the button stays as decision 45 has it.

## Context

Decision 45 turns the Fetch icon about once a second while any fetch runs. A turning icon is what every app does for "busy", and it says nothing about a fetch in particular. Pushing and pulling get the house from the mark ([decision 21](0021-draw-the-houses-animations-from-joints.md)), and a fetch, which Roga runs far more often than either, got none of Roga's character.

## Decision

**While a fetch runs, the house drops through the Fetch button.** The icon slides down and out of the button, the house comes in from the top, hanging by a thread tied to its chimney with its legs spread, and goes on down and out, and then the icon slides back in from the top. One drop takes 1.4 seconds, and the drops repeat for as long as the fetch runs. The house slows down as it passes the middle, so that it can be seen at the button's size.

**The house holds still on the way down.** It's one pose that slides as a whole, rather than an animation of its joints, so it isn't one of the house's animations in Settings or in Window > House Animations. The pose is built from the same joints as those animations. The chimney is off to one side, so the house hangs tipped back, with its middle under the thread, and the thread fades out above it, as if it went on up out of sight.

**The house is orange, as it is everywhere else, and the thread is the icon's gray**, so that it darkens with the icon when the pointer is over the button.

**Everything slides inside the button's 28 points.** The button's square clips it, so with the pointer over the button, the gray square is the window it all passes through.

**The drop it's on always finishes**, as the turn did, so even a quick fetch shows a whole drop, and the icon comes back to rest. A fetch that starts again before the last drop ends carries on from where the strip is, without a jump.

**Someone who asked for less motion still sees the icon fade in and out**, as in decision 45.

## Consequences

- The fetch Roga starts by itself drops the house too, so the house shows each time Roga becomes active and finds a remote to fetch from. If that turns out to be too often to stay funny, the quiet fetch could go back to something plainer while a fetch someone asked for keeps the house.
- The house's speed in Settings doesn't apply to the drop, which always takes 1.4 seconds.
- `FetchDrop` draws the strip, and `HangingHouse` holds the pose. Changing the mark's house means cutting the body again for `HouseOutline`, as for the other animations, and the knot on the chimney may need to move with it.
