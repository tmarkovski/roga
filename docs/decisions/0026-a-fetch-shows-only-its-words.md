# 26. A fetch shows only its words

Accepted on 2026-11-04.

## Context

[Decision 21](0021-draw-the-houses-animations-from-joints.md) has the house waddle while a fetch runs, and [decision 25](0025-the-house-zooms-and-the-words-move-the-way-the-commits-go.md) has it zoom in and out around that. A fetch doesn't move the branch, so all the waddle says is that something's happening, and the word already says that. It also makes a quick fetch wait for a whole cycle of the house before saying it's done.

## Decision

**A fetch has no house.** **Fetching…** opens in place of the counts, fading in where it will stay, as decision 25 has it, and moves what's to its right along. It starts straight away, because there's no zoom to wait for. The counts fade out and the words open on the same curve, so what's to their right moves steadily rather than following the counts out and then the words back.

**It doesn't wait to be seen.** The words change to **Fetched** as soon as git is done, and close up after 3 seconds as the other notes do.

**Undoing a pull keeps its waddle.** It's the only other action with no direction to show, but it does change the worktree.

## Consequences

- Waddle now shows in the title row only for undoing a pull. It stays in Settings and in Window > House Animations with the others.
- A fetch that's quicker than the words take to open, about 0.3 seconds, shows **Fetching…** only in passing on the way to **Fetched**.
- Fetching again while **Fetched** still shows changes the words in one step, which moves what's to their right by about 13 points in one frame. We tried having them turn into each other, as **Fetching…** turns into **Fetched**, but in that direction what's to the right overshoots by about 25 points.
- When the counts come back, after any action, their room now opens a frame at a time, with `PartWidth`. With only a fade they took all their room at once while the words were still open, and what's to their right jumped about 50 points before settling.
