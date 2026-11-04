# 25. The house zooms in and out, and the words move the way the commits go

Accepted on 2026-11-03.

## Context

[Decision 19](0019-pull-and-push-from-the-branch-in-the-title-row.md) and [decision 21](0021-draw-the-houses-animations-from-joints.md) have the house and **Pulling…** replace the counts in one step, and **✓ Pulled 3** replace those in another. Everything to the right of them jumps each time. That's abrupt for the moment yaga has the most character, and only the house says which way the commits are going.

## Decision

**It goes in steps.**

1. The house zooms in and fades in, in about a quarter of a second, while the counts fade out.
2. The words come out beside it, and everything to their right moves along to make room.
3. When git is done, the words change to what happened and the house zooms out, while the words slide over to where it was.
4. After 3 seconds the words close up, and the counts come back if there are any.

**The words move the way the commits go**, as the house's lean does.

- **Pushing** comes out from behind the house, with its trailing end against what's to its right, so that it looks like it's pushing that along. A force push and deleting from a remote do the same, because they show the same house.
- **Pulling** comes in from the right, toward the house. What's to its right has to move the other way to make room, so the words keep gliding after that has stopped, for 0.45 seconds rather than 0.3. Otherwise most of their travel happens while they're faint and clipped, and they don't look like they're moving.
- **Fetching** and **undoing a pull** have no direction, so their words fade in where they'll stay.

**What happened is one plain word.** **Pushed** and **Pulled** have no checkmark and no count. The checkmark goes from every note in this place, including **Deleted fix-login**, which has no house and so only has its words open and close.

**Someone who asks for less motion gets each step straight away**, with the still house from decision 21.

## Consequences

- This changes the note that decisions 19 and 21 describe as **✓ Pulled 3** and **✓ Pushed 1**. How many commits moved isn't said any more. History and the counts show where the branch ends up.
- The room for the words is animated by laying out again on every frame, in `PartWidth`, for about 0.3 seconds each time. We first let SwiftUI animate a frame's width, which costs nothing per frame, but what's to the right then drifted ahead of the words, so they didn't look like they were doing the pushing.
- That width is rounded to whole points. Otherwise the title row's width passes through fractions of a pixel, and the repository's and branch's names at the other end of it wobble by half a point.
- The house still plays one cycle at least, and that time includes its zoom. At 3× speed the words have only just landed when they change.
- In a narrow window, the words opening can push the commit count out of the title row, as the counts do.
