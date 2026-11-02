# 14. Keep every added repository in the sidebar, and save the list in Application Support

Accepted on 2026-11-01. This settles a question that [decision 13](0013-repositories-in-a-sidebar.md) and the [main window](../main-window.md) left open.

## Context

Decision 13 put repositories and their worktrees in a sidebar, but left open which repositories it lists. It could list only the repositories open in that window, which close the way tabs did. It could also list every repository the user has added, like the projects in Claude's sidebar.

Until now, yaga saved the folder each window showed with the window, through SwiftUI's window restoration. That doesn't survive a normal quit. macOS's "Close windows when quitting an application" setting is on by default, and with it, quitting with Command-Q throws away every window's saved state. So yaga forgot its repositories each time it quit, unless the user quit with Option-Command-Q. Closing the last window lost them too.

Release 1 is for someone who keeps yaga next to a terminal while agents work in a few repositories. They come back to the same repositories every day, and the sidebar can only show which worktree changed if those repositories stay in it.

## Decision

- The sidebar lists every repository the user has added, in the order they were added, until the user removes one. Every window lists the same repositories, and each window selects its own worktree.
- yaga saves the list in `repositories.json` in its folder in Application Support (`~/Library/Application Support/build.yaga.app/`). For each repository, it saves its git directory, a bookmark to that directory, and whether its worktrees are shown. It also saves the worktree selected last.
- Worktrees aren't saved. git lists them each time yaga opens a repository and whenever yaga becomes the active app, so worktrees that agents add or remove appear and disappear without the user doing anything.
- Each window saves its selected worktree with window restoration. A window that opens without one, because macOS didn't restore it or because the user opened a new window, shows the worktree selected last.

## Consequences

- yaga opens with the same repositories after a quit, whatever the user's setting for closing windows.
- Launching always opens a window with the sidebar. The window that welcomes a new user is the same window with an empty list, so the problem the [window tabs preview](../../prototypes/window-tabs/README.md) found, that SwiftUI doesn't reopen a closed welcome window, goes away.
- A repository that moves to another folder on the same disk is found again through its bookmark. One that can't be found stays in the list, dimmed, with commands to find it or remove it, so that a disk that isn't mounted doesn't empty the list.
- A file yaga can't read is moved aside as `repositories.unreadable.json` rather than overwritten.
- Each listed repository keeps a session open, with its `cat-file` process, even while no window shows it. That makes the open question in [ARCHITECTURE.md](../../ARCHITECTURE.md#still-open) about what a session does while nothing shows it more pressing.
- Settings for one repository, such as branches hidden from history, have a place to go: the repository's entry in the same file.
