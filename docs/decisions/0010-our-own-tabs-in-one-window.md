# 10. Show repositories as tabs that yaga draws itself

Accepted on 2026-11-01. Partly superseded by [decision 13](0013-repositories-in-a-sidebar.md), which replaces the tab strip with a sidebar. The rest of this decision still holds.

## Context

People often have several repositories open at once, and when they work with agents, each repository can have several worktrees. We considered three ways to arrange them:

- **A window for each repository, grouped with macOS's native window tabs.** This is how Finder, Safari and Xcode work.
- **One window with tabs that yaga draws itself.** GitKraken works this way, and so does the Claude app.
- **One window with a sidebar that lists every repository.**

We built the first option as a [preview](../../prototypes/window-tabs/README.md). Native tabs worked. With `tabbingMode = .preferred`, every repository opened as a tab in one window, and each tab could carry a tooltip and one small accessory view. macOS also provided the keyboard shortcuts, dragging a tab out into its own window, and restoring windows after a relaunch.

The preview also showed the limits. The system owns how the tab bar looks: rounded Liquid Glass tabs, with a plus button that's always there. A tab can show nothing beyond its title and that one small view. Launching needed extra work, too, because AppKit only adds a new window as a tab of the key window.

We want yaga's tabs to have a design of our own, closer to the Claude app, and we want one window to be the central place for working with repositories. Sharing state between tabs doesn't depend on the choice, because each repository's state lives in a session that doesn't belong to any window.

## Decision

- A yaga window holds tabs that yaga draws itself, one for each open repository. yaga turns off macOS window tabbing.
- There can be several windows, each with its own tabs. A command moves a tab to a new window. Dragging a tab out of the window isn't part of release 1.
- Each tab shows one repository. The tab lists the repository's worktrees, and choosing one changes what the tab shows. A worktree can also be opened in a tab of its own.
- Each repository's state lives in a session that doesn't belong to any window or tab, and tabs that show the same repository share it.
- Hidden tabs keep their views, so switching back to one restores its scroll position and selection without reloading anything.
- The visual design of the tabs comes from the main window wireframe.

## Consequences

- We build and maintain the tab strip ourselves. That covers:
  - drawing, selecting and closing tabs
  - reordering them by dragging
  - behavior when there are many tabs
  - context menus
  - keyboard shortcuts, including Control-Tab, Command-1 to Command-9, and Command-W closing a tab rather than the window
  - VoiceOver support
  - saving and restoring each window's tabs

  We estimate one to two weeks of work for a first version we're happy with.
- The tabs won't follow changes to the system's design automatically. Keeping them looking right on new versions of macOS is our job.
- Comparing two repositories or worktrees side by side needs a second window or, later, a split view inside the window.
- The vision said yaga uses standard tabs. It now says yaga keeps the behavior Mac users expect while drawing some of its own interface where a design of our own serves people better.
- Menu commands act on the selected tab of the key window, which each window publishes through SwiftUI's focused values.
- [ARCHITECTURE.md](../../ARCHITECTURE.md#windows-and-tabs) describes how windows, tabs and sessions fit together.
