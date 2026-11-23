# 99. Bring a sidebar row's details in as they load

Accepted on 2026-11-23. This changes one rule of [decision 48](0048-a-second-line-under-a-sidebar-row-while-theres-something-to-say.md): a row's height still changes at once, except while the list is loading, when the whole list moves together.

## Context

The sidebar lists the saved repositories' names as soon as the window opens, and fills in the rest as git answers. A repository's branch comes when it opens, and its count of uncommitted files, its conflicts and any merge or rebase that stopped partway come once a look has run `git status` in each of its worktrees, in four repositories at a time. Across a list of 16 at launch, that takes from a few hundred milliseconds to a few seconds, depending on how large the repositories are.

Each of those pieces appeared at once where it went. Counts popped in one after another, a row that grew a second line pushed the rows under it down, and a list sorted by uncommitted changes reordered itself in jumps while the person was reading it. Nothing said which rows were still waiting either, so a row without a count could be a worktree with nothing to commit or one that hadn't been counted yet.

## Decision

**A row's name is faint until its count is in.** A repository's row and the rows of its worktrees draw their names at 45% strength until the first look has counted the repository's files, and then come up to full strength over about half a second, a little after the count arrives. Since looks run four at a time, at launch the rows come up a few at a time. A repository that's missing or can't be opened keeps its own dimmed look and its label, since it will never be counted.

**What arrives comes in softly where it goes.** A count, its triangle, and the words **Missing**, **Can't open**, **Deleting…** and **Folder missing** fade in out of a three-point blur and grow from 60% of their size toward their right end, which stays where it is, so the counts stay lined up. A repository's branch and its chevron fade in out of the same blur without growing, since growing would move them along the line they're on. A count that changes later rolls to its new number, upward when it went up and downward when it went down, and one that goes away fades out.

**A second line fades in, and the row still takes its new height at once,** for decision 48's reason: animating one row's height doesn't carry the rows under it along. A line that goes away goes at once, because the row is already short again and fading words would hang over the row below.

**While the list loads, it moves together.** The changes that come with a repository opening, or with its files being counted for the first time, animate across the whole list. The rows a repository brings when it opens, such as its linked worktrees, fade in, the rows under a row that grows a second line slide down with it, and in a list sorted by uncommitted changes, rows slide to their places. A repository that's just been added fades in too, since it hasn't been counted yet. This is the exception to decision 48, and it's safe because the whole list animates together, so nothing under the growing row jumps. Expanding and collapsing a repository, grouping, sorting, removing a repository and anything else someone does to the list still happen at once, as before.

**Reduce Motion,** in the Accessibility settings, turns the blur, the growing and the rolling numbers into plain fades, and the rows that loading moves take their places at once.

We didn't run a shimmer over the names while they load, as skeleton screens do. It would redraw every faint row on every frame during launch, which is when the main thread has history to draw, and across a list of dozens it reads as busy rather than subtle. We didn't hold a gray placeholder where each count goes either, because most worktrees have nothing to commit, so the placeholder would usually turn into nothing.

## Consequences

- At launch the list settles into place rather than jumping, and once a row is at full strength, no count means nothing to commit rather than not counted yet.
- A row stays faint for as long as its first `git status` takes, and a repository whose look is waiting for its turn stays faint until then. In a large repository that can be a second or more after history shows.
- The list now reads whether each repository is open and has been counted, so it works out its rows once more per repository at launch, when each finishes. Sorted by name, the list didn't read the counts before.
- Two rows that swap places while a sorted list loads cross for about a third of a second, and their names overlap as they pass, since the rows have no fill of their own.
- The tabs along the top of the window show the same counts, and they still appear at once.
- A window counts the worktree it shows by itself, and when that count arrives before the list's own look, it shows on a row that's still faint until the look finishes.
