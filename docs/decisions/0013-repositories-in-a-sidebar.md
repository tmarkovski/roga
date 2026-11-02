# 13. List repositories and their worktrees in a sidebar

Accepted on 2026-11-01. This replaces the tab strip from [decision 10](0010-our-own-tabs-in-one-window.md).

## Context

Decision 10 gave each open repository a tab that yaga draws itself, with the repository's worktrees listed in a navigator on the right. Before building the tab strip, we sketched other arrangements, taking ideas from the Claude and ChatGPT desktop apps:

- **Tabs on top**, as decision 10 describes. They take no width, because they share the top row with the window's buttons. Past about eight tabs the strip gets crowded, worktrees only appear in the navigator, and a worktree opened in a tab of its own looks like another repository.
- **Repositories at the top of the navigator.** Each repository expands into its worktrees, and the navigator collapses to a narrow strip of repository icons instead of disappearing. This adds no column, but it puts the window's main navigation on the right, where Mac apps put inspectors.
- **A sidebar on the left** that lists repositories with their worktrees under them, the way Claude and ChatGPT list sessions under projects, and a panel on the right for the selected repository's branches, remotes, tags and stashes.
- **A strip of icons on the left that switches views**, such as history, changes, branch review and stashes, with repositories staying in tabs. Its width doesn't depend on how many repositories are open, but it's a third way to move around the window, on top of the tabs and the navigator.

Release 1 is for someone who keeps yaga next to a terminal while several agents work, often in more than one repository. The first thing they look for is which worktree changed. They need the lists of branches and tags less often, and those lists can be long: Linux has hundreds of tags.

## Decision

- A sidebar on the left of the window lists repositories, each with its worktrees under it. A worktree row shows its branch, its folder, when it last changed, and how many uncommitted files it has. Choosing a worktree shows it in the rest of the window.
- A panel on the right lists the selected repository's branches, remotes, tags and stashes. It replaces the navigator.
- Both are the sidebar and the inspector that macOS provides, not views that yaga draws itself. The sidebar runs the full height of the window, with the window's buttons at its top. Either one can be hidden.
- yaga no longer draws a tab strip, and it still turns off macOS window tabbing.
- The rest of decision 10 stands. There can be several windows. Each repository's state lives in a session that doesn't belong to any window. The window keeps the views of worktrees it isn't showing, so switching back to one restores its scroll position and selection without reloading anything.

## Consequences

- Every worktree of every listed repository is visible at once, with its uncommitted files, which is what someone watching several agents looks for first.
- Hiding the sidebar and the panel, their keyboard shortcuts, VoiceOver support and remembering their widths come from macOS. Most of the work decision 10 estimated for the tab strip goes away, and so does the question of what the strip does when the tabs don't fit.
- The two side columns take width. With both open, a window 1,200 points wide leaves about 700 points for history and the diff, so the panel on the right has to collapse first when the window gets narrow.
- Showing uncommitted counts for every listed worktree means a repository's session keeps watching the file system while none of its worktrees is showing. The roadmap allows status up to 300 ms on a repository the size of Linux, so sessions for repositories that aren't showing may need to update their counts less often.
- Opening a worktree in a tab of its own becomes opening it in a new window. Comparing two worktrees side by side already needed a second window.
- Command-W closes the window, as in other Mac apps. Command-1 to Command-9 and Control-Tab no longer switch tabs, and what they do instead is still open.
- Menu commands act on the selected worktree of the key window, which each window publishes through SwiftUI's focused values.
- The vision used the tabs as its example of interface that yaga draws itself. It now uses the commit graph.
- [docs/main-window.md](../main-window.md) describes the layout, and [ARCHITECTURE.md](../../ARCHITECTURE.md#windows-and-the-sidebar) describes how windows, the sidebar and sessions fit together. The [main window preview](../../prototypes/main-window/README.md) still shows the tabs.
