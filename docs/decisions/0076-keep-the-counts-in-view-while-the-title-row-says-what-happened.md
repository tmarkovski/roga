# 76. Keep the counts in view while the title row says what just happened

Accepted on 2026-11-13. This changes the last of [decision 25](0025-the-house-zooms-and-the-words-move-the-way-the-commits-go.md)'s steps, where the counts came back only once the words had closed up.

## Context

After a commit, the title row said `Committed 9f2c1ab` with an Undo button for 8 seconds, in place of `↑1`. So the button that pushes what was just committed was gone for the 8 seconds when someone was most likely to want it. A discard hid the counts the same way, with its own Undo, and **Pulled** hid `↑` for 3 seconds after a pull that left the branch ahead.

We also sketched a card floating over the top of history that would hold the Undo, with a line draining along its edge for its time on screen. It would make Undo easier to notice, but keeping the counts in view fixes what was getting in the way, and it's a small change, so we did that first.

## Decision

**The counts give way only to the house.** While a pull, a push, or anything else with a house runs, the house still works in their place, as [decision 19](0019-pull-and-push-from-the-branch-in-the-title-row.md) has it. A commit, a merge, a rebase, a cherry-pick, a revert, a fast-forward or a submodule update has no house, so its words open after the counts, which stay. When git is done, the counts come back as the words change to what happened, rather than after they close up. A discard says what went after the counts too.

**The counts come before the words**, right after the branch, where they sit the rest of the time, so the row reads `main ↑2  Committed 9f2c1ab  Undo`. After the words, `↑` would sit right beside Undo, which is orange as well, and a slip there would push the commit someone meant to take back.

**Clicking a count while git runs does nothing**, as while a fetch runs ([decision 45](0045-fetch-and-new-branch-as-buttons-and-the-commit-count-with-history.md)). Once git is done, `↑` pushes, and the push ends the commit's words and its Undo, as any new action does.

## Consequences

- The left part of the title row is wider by the counts while words show. In a narrow column, the branch's name is cut shorter for those seconds, and the number of commits at the right end can go, as decision 25 says the words could already make it do.
- After a pull that leaves the branch ahead, `↑` opens before **Pulled** while the house zooms out, so the words move right in the same moment as the house's room closes.
- Undo is no easier to notice than before. The floating card is still an option if that turns out to matter.
