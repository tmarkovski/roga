# 124. Put Pull and Push beside Fetch

Accepted on 2026-11-28. This moves the counts that pull and push from right after the branch, where [decision 19](0019-pull-and-push-from-the-branch-in-the-title-row.md) put them, to the right end of the branch's row, just before Fetch. The house of a push or a pull moves with them, and Roga's words stay after the branch.

## Context

Decision 19 put `↓3` and `↑1` right after the branch, so that the row read as a sentence, as in `agent/fix-login ↑2`, and [decision 95](0095-a-repositorys-worktrees-as-tabs.md) kept them there when the branch moved to a row under the tabs. Since then, the row has gained two things after the counts: Roga's words while git runs or has just run ([decisions 25](0025-the-house-zooms-and-the-words-move-the-way-the-commits-go.md), [76](0076-keep-the-counts-in-view-while-the-title-row-says-what-happened.md) and [93](0093-keep-the-house-going-while-the-title-row-says-pushed-or-pulled.md)), and the agent's line ([decision 100](0100-say-what-the-worktrees-agent-is-doing-in-the-branch-row.md)). [Decision 120](0120-say-how-far-the-branch-is-from-main-and-make-its-menu-a-popover.md) also put a line under the branch's name that says how far the branch is from the main branch on the remote.

With the row this full, the counts' place cost more than it used to:

- The counts start wherever the branch's name ends, so they're in a different place in each worktree's tab, and they move when a branch is renamed.
- A count shows only when there's something to pull or push, so a commit makes `↑1` appear and moves the agent's line to the right, and the push moves it back.
- Fetch, Pull and Push all talk to the remote, but Fetch was at the right end ([decision 45](0045-fetch-and-new-branch-as-buttons-and-the-commit-count-with-history.md)) and the other two were at the left.

## Decision

**The counts sit at the right end of the branch's row, just before Fetch,** 2 points from it, as Fetch is from New Branch. They still show only when there's something to pull or push and are orange when a click would run at once, and the gray `↑ Push` of a branch that's never been pushed and the menu that a diverged branch's `↑` opens are as decision 19 has them. Fetch and New Branch stay where they were, and the counts come and go to their left, opening from their right end.

**The house of a push or a pull works in the counts' place,** beside Fetch, where the push or the pull was asked for, as the house drops through the Fetch button during a fetch ([decision 57](0057-the-house-drops-through-the-fetch-button.md)). It zooms in and out from its right end. Force pushing and deleting a branch from a remote show the push's house, so they play there too.

**Roga's words stay after the branch,** where the agent's line is when they aren't showing, as in `Pushing to origin…`, `Pulled` and `Committed 9f2c1ab` with Undo. They fade in where they'll stay, rather than coming out from behind the house or in toward it as decision 25 had them, because the house is now at the other end of the row. The house still leans the way the commits go. Decision 93's steps don't change: the house zooms in, the words open, the words change to what happened while the house keeps going, and after 3 seconds the house zooms out, the words close up and the counts come back, all at once.

**Undoing a pull, aborting, and continuing a rebase waddle before the words,** after the branch, because Undo and the menu for a worktree that's stuck partway, which start them, are there. What the worktree is stuck partway through, as in `⚠ Rebasing main · 2 conflicts` ([decision 28](0028-show-a-worktree-thats-stuck-partway.md)), also stays after the branch, since it says what state the worktree is in rather than offering something to do with the remote, and the waddle works in its place. While it shows, there are no counts, as before.

**With the house off in Settings,** a push or a pull shows its words after the branch, and the counts stay where they are while git runs ([decision 112](0112-let-the-house-be-turned-off-in-settings.md)).

## Consequences

- The counts and Fetch are in the same place in every worktree, whatever the branch is called.
- The agent's line starts right after the branch and doesn't move when a count comes or goes.
- The row no longer reads as a sentence. `↑2` still says that the branch has commits to push, but it's at the other end of the row from the branch's name.
- `↑` is now far from Undo, so a slip can't push a commit that someone meant to take back. Decision 76 kept the words after the counts to prevent that.
- When you click `↑`, the house plays where you clicked, and the words about it open at the other end of the row.
- The words no longer move the way the commits go, so a push and a pull look alike except for the house.
- When the row is short of room, the counts, Fetch and New Branch stay whole, as before, and the agent's words are cut first.

## Alternatives considered

- **Move only the counts, and keep the house beside the words after the branch.** It would keep decision 25's words that move the way the commits go, but clicking `↑` would start the house at the other end of the row, and the counts would have to sit there doing nothing while git runs.
- **Move the words to the right end with the house.** The house and its words would stay together, but Undo would sit beside `↑`, which is the slip decision 76 avoided, and a commit's words would still have to open after the branch.
- **Fold Pull and Push into one button with Fetch,** as some Git clients do. It would take less room, but you'd have to open the button to see how far the branch is behind or ahead, which the counts show at a glance.
