# 40. The repository's name opens a menu of its worktrees

Accepted on 2026-11-05. This changes how the title row starts, which [decision 19](0019-pull-and-push-from-the-branch-in-the-title-row.md) set as the repository's name in plain text, and fixes [issue 12](https://github.com/tmarkovski/yaga/issues/12) for every menu that `RefMenu` draws.

## Context

The title row read `agents-demo main ↓3 ↑1`. The repository's name looked the same in the main worktree and in a linked one, so nothing in the window said which one it showed. With the sidebar closed, the only way to another worktree was through the refs panel. Agents work in linked worktrees, so that's the question someone watching them asks most.

The design canvas's Worktree switcher page compared three labels for the name and two orders for the menu's rows, in dark and light, with every state a row can be in, and the sidebar with and without icons. We chose label A and rows A.

## Decision

**The repository's name is a chip, like the branch's.** Lucide's `folder-git` comes before the name in the main worktree, and `folder-git-2` in a linked one, which are `Icon.repository` and `Icon.worktree`. A chevron comes after it. The chip keeps the repository's name in both. The branch chip beside it already names the worktree the way the sidebar does, so the worktree's folder would say it twice, and agents name their folders at random, as in `brave-otter-41`.

**Its menu lists the repository's worktrees on two lines,** the main worktree first and then the linked ones in the sidebar's order, with a checkmark on the one the window shows.

- The first line is the branch, as the sidebar names a worktree, or `detached at 86b3386a`.
- The second line says only what applies, in this order: **Deleting…** or **Folder missing**, what the worktree is stuck partway through ([decision 28](0028-show-a-worktree-thats-stuck-partway.md)) in red when there are conflicts, `↓3 ↑2` against its upstream or **Upstream gone**, **Locked**, and last, its folder, with `~` for the home folder. Only the folder gets cut short, in its middle, so what's going on stays whole and the folder keeps its name.
- The count of uncommitted files ends the row, in orange, or in red with a triangle when some have conflicts, as in the sidebar.
- A missing or deleting worktree can't be chosen. Choosing the one on screen does nothing.
- After them come **New Worktree…**, which opens New Branch with In a new worktree ticked, and **Show in Finder** and **Open in Terminal** for the worktree on screen.

The menu opens at once with what's already known, and never waits on git:

| What | Where it comes from | What it costs |
| --- | --- | --- |
| Uncommitted files and conflicts | The sidebar's look at each worktree, which runs `git status` | Nothing more |
| A merge or rebase stopped partway | The files git keeps for it, `MERGE_HEAD`, `rebase-merge` and `rebase-apply`, in the git directory that the worktree's `.git` names | A few file checks for each worktree, with no git |
| `↓` and `↑` | One `git for-each-ref` with `%(upstream:track)` for every worktree's branch, at utility priority, after the counts | One git for each repository at each look |
| Locked, missing | `git worktree list` | Nothing more |

The worktree on screen uses what its own model last read instead, which is fresher.

**Agent status isn't in it yet.** It waits for hooks, as [decision 16](0016-a-rail-of-organizations-in-the-sidebar.md) says, and when it comes, it goes at the front of the second line. A worktree that `git worktree lock` locked says **Locked**, and nothing more is guessed from that.

**The menu is a `RefMenu`, with a new kind of row.** SwiftUI's menus can't draw a second line in colors. A choice has two lines, an icon, a checkmark and a count. In a menu of choices, headers and commands start where the choices' titles do, without icons of their own, so that nothing has an icon only to line up.

**Return now chooses a row in every `RefMenu`.** macOS ignores Return while a row that draws itself is highlighted, and leaves the menu open. The menu hands the keys to the view of the row it's highlighting, if that view takes them, so each row hears Return itself and passes every other key on. As a menu opens, though, it also hands them to the first row that would take them, and highlights that row, so no row takes them for the first tenth of a second. These were tried and dropped:

- Watching keys with a local event monitor, which never sees a menu's keys.
- Choosing when the menu closes, because Return doesn't close it.
- A disabled row that's too thin to see, to hear the keys for the whole menu, because the menu never hands keys to a disabled row.
- Letting only the current choice take the keys, because the menu takes them away again as the highlight moves.

**The icons stay out of the sidebar.** Its line already says which rows are linked worktrees, and a repository's row is its main worktree, so an icon on every row says that twice and pushes the names right. They go where nothing else says it: the title row and its menu.

**A repository's name in the sidebar is never bold.** It used to be bold while any of its worktrees had uncommitted files, which the orange counts already say.

## Consequences

- The title row is about 40 points longer. In a narrow column the chip keeps its full width, and the branch's name truncates first, as before.
- `↓` and `↑` for a worktree that isn't on screen are as old as the sidebar's last look, which runs when Roga becomes active and after anything Roga changes in the repository.
- VoiceOver's press on the chip opens the menu, and each worktree and command is an action of the chip too. Whether VoiceOver reads a choice's second line in the menu hasn't been checked.
- The tenth of a second is a timing, not something macOS tells us. If the arrow keys highlight a row sooner than that, Return does nothing until the highlight moves again. If macOS changes how it hands keys to rows, Return stops choosing again, and nothing else breaks.
- `MenuUI` now depends on `IconUI`, for the checkmark, since the app draws no SF Symbols.
