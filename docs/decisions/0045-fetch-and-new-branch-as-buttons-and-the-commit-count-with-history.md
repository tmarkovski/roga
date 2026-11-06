# 45. Fetch and New Branch as buttons, and the number of commits with history's commands

Accepted on 2026-11-06.

## Context

[Decision 19](0019-pull-and-push-from-the-branch-in-the-title-row.md) has the title row read `agents-demo  main ⌄  ↓3 ↑1 · 128 commits`, with Fetch and New Branch in the branch's menu. It turned down icons at the right end of the row, because they "read as more of history's commands and don't say what they act on". [Decision 26](0026-a-fetch-shows-only-its-words.md) has **Fetching…** open in place of the counts while a fetch runs.

That row had three problems ([issue #18](https://github.com/tmarkovski/yaga/issues/18)):

- **It jumps.** **Fetching…** and **Pulling…** open in front of the number of commits and push it along.
- **The number of commits describes the wrong thing.** It counts every commit history shows, from `git log HEAD --branches --remotes --tags`, rather than the branch's, but it sits after the branch.
- **Fetch takes a trip through the menu.** Roga fetches when it becomes active ([decision 20](0020-fetch-when-yaga-becomes-active.md)), but an agent pushing while the window stays in front never triggers that, and decision 20 said that fetching only on request "would need a visible button".

We compared eight Git clients on what they keep in their top row ([the research](https://github.com/tmarkovski/yaga/issues/18#issuecomment-6686176818)). Nearly every full client keeps fetch, pull and push visible. They're split on New Branch: Fork and GitKraken give it a button, and GitHub Desktop, VS Code and Xcode keep it in the branch's menu. None puts a total number of commits in its top row, and Tower's is in its History view's tab bar. And they keep the top row still while git runs: GitHub Desktop's button keeps its width, Sublime Merge has a fixed area for it, and GitKraken reserved a slot so that other buttons don't shift.

## Decision

The row reads `agents-demo  main ⌄  ↓3 ↑1`, then a gap, then Fetch and New Branch as icons, then `128 commits` in gray, history's Order menu and the refs panel's button.

**The number of commits moves to the right end**, just before history's Order menu. Next to history's commands it reads as being about history, as Tower's does, and nothing pushes it there. Its tooltip says that it counts every branch, remote branch and tag. It's still the first thing to go when the row is short of room.

**Fetch is a permanent icon button**, with the hollow node from decision 19. Its tooltip says where it fetches from, when Roga last did, and the command, as in **Fetch from origin**, **Last fetched 4 min ago** and `git fetch origin`. After a fetch that failed it says **Couldn't reach origin** instead. It's off when there's no remote to fetch from.

**The Fetch icon turns while any fetch runs**, including the one Roga starts by itself, about once a second, and nothing opens in the row: no **Fetching…**, and no **Fetched** either. The icon coming to rest says the fetch is done, and a count appears or ticks up when it found something. The icon finishes the turn it's on rather than snapping back, so even a quick fetch shows a whole turn. Clicking it while Roga's own fetch runs stops that one and fetches again, so that anything that goes wrong is reported. Someone who asked for less motion sees the icon fade in and out instead.

**New Branch is a permanent icon button beside Fetch.** It opens the same popover, with **In a new worktree**, and the popover now hangs from this button however it was asked for: the button, the branch's menu, Shift-Command-B, or New Worktree… in the menu of the repository's worktrees. The button looks pressed while the popover is open, and the branch's chip no longer does. Agents start a branch per task, which is why New Branch earns the place rather than Stash or Pop. Its tooltip names where the branch starts, as in **New Branch from main**.

**Pull and push stay as the counts.** Permanent buttons would mostly sit gray with nothing to do.

**The branch's menu keeps everything it has**, so Fetch and New Branch are still there for the keyboard.

**A slow checkout's words move to just before Fetch**, where history's commands used to start, so that they open without moving the buttons.

**When the row is short of room**, the number of commits goes first, then the branch's name truncates, down to a few letters, then the repository's name does. The counts stay, and so do the two buttons.

Decision 19's objection to icons at the right end is less true of these two. Fetch acts on the remote rather than the branch, the tooltips say what each acts on, and a gap keeps them apart from history's Order menu.

## Consequences

- This revises decision 26: a fetch shows nothing in the row. **Undoing…** keeps its waddle, and a commit still shows only its words.
- It revises decision 20 too, which said nothing shows while Roga fetches by itself: the Fetch icon turns. A failure is still quiet, and only the branch's menu and the Fetch tooltip say so.
- While a fetch someone asked for runs, the counts stay on screen, where they used to give way to **Fetching…**. Clicking one does nothing until the fetch is done, as before.
- The buttons stay put while the counts and **Pulling…** come and go, but they move along when the number of commits comes or goes, as when switching to a worktree with a longer branch's name in a narrow window, or when it gains a digit.
- The title row keeps room for the two buttons, 78 points. In the narrowest middle column, 400 points, that leaves room for the repository's chip as only its icon and chevron. The chip's menu still says which repository it is, and so do the sidebar and the window's title.
- The toolbar keeps an item's room after what's in it shrinks, so the number of commits is added and removed as an item, by how wide its words are, rather than shrinking to nothing.
- The left part of the title row reports its width on every frame while words open and close in it, to decide whether the number of commits fits. Only history's commands read it, so the rest of the window doesn't redraw.
