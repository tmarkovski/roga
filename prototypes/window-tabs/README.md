# Window tabs preview

This is a throwaway preview of how yaga could show repositories as native macOS window tabs. Each repository is its own window, and the windows share one tab bar, so by default you see a single window with a tab per repository. It isn't part of the app.

We decided to draw our own tabs instead ([decision 10](../../docs/decisions/0010-our-own-tabs-in-one-window.md)). What the preview showed about launching and restoring windows still applies.

The commit list and the details pane are quick SwiftUI stand-ins. The app will use an `NSTableView` (decision 7) and a TextKit 1 text view (decision 9).

## Running it

```bash
prototypes/window-tabs/run.sh --open-all
```

The script builds the preview, wraps it in an app bundle, and opens it with:

- a small demo repository whose worktrees look like coding agents at work, which `make-demo-repo.sh` creates in `bench-repos/agents-demo`
- this repository
- the Linux and git clones in `bench-repos/`, if they exist

Without `--open-all`, it shows a welcome window where you choose what to open.

## Things to try

- Switch tabs with Control-Tab, or see them all with Shift-Command-Backslash.
- Drag a tab out into its own window, and choose Window > Merge All Windows to bring it back.
- Open another repository with Command-O. It opens as a new tab.
- Click the "+" at the end of the tab bar to open an empty tab, then choose a repository for it.
- In `agents-demo`, click a worktree in the sidebar to switch to it, or right-click it and choose Open in New Tab.
- Hover over a tab to see the repository's path. An orange dot on a tab means one of its worktrees has uncommitted changes.

## What it showed

- `NSWindow.tabbingMode = .preferred` makes new repository windows open as tabs regardless of the system's "Prefer tabs when opening documents" setting.
- AppKit only tabs a new window into the key window. When another window is key, such as a welcome window, yaga has to add the new window to the existing tab group itself.
- Each tab can carry a tooltip and one small accessory view, which is enough for a dot that shows uncommitted changes.
- SwiftUI doesn't reopen a single `Window` scene, such as a welcome window, if it was closed when the app quit. The real app has to decide what to show at launch when no windows are restored.
