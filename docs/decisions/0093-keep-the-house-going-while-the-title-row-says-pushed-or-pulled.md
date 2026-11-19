# 93. Keep the house going while the title row says Pushed or Pulled

Accepted on 2026-11-18. This changes the third of [decision 25](0025-the-house-zooms-and-the-words-move-the-way-the-commits-go.md)'s steps, where the house zoomed out as the words changed to what happened, and, for an action with a house, the moment [decision 76](0076-keep-the-counts-in-view-while-the-title-row-says-what-happened.md) brings the counts back.

## Context

A push to a nearby remote takes well under a second, so the house played its one cycle beside **Pushing…** and zoomed out as soon as the words changed to **Pushed**. It was on screen for about as long as it took to notice that something had moved, and then the title row went straight back to the counts with only the words left. The animation is the part of the title row with the most character, and most people saw little of it.

## Decision

**The house keeps going while the words say what it did.** When git is done, **Pushing…** changes to **Pushed** and **Pulling…** to **Pulled**, and the house stays beside them, still pushing or heaving. Undoing a pull keeps its waddle the same way.

**Everything goes at once.** When the words have had their 3 seconds, the house zooms out and the words close up as the counts come back, in one step.

**Words that something else announces take the house away.** A discard just after a push says **Discarded** without the push's house, and its counts come back with it, as decision 76 has it.

## Consequences

- The counts stay hidden for 3 seconds longer after a pull or a push. After a pull that leaves the branch ahead, `↑` comes back with the counts rather than as **Pulled** shows, which takes back the second consequence of decision 76 for a pull. Push in the branch's menu and Shift-Command-P still work while the words show.
- The house still plays a full cycle beside **Pushing…** or **Pulling…** before the words change, so a quick git still shows both.
- A commit, a merge, a rebase and anything else without a house is unchanged: its words open after the counts, which stay.
