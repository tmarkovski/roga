# Main window preview

This is a throwaway preview of Roga's main window with the tabs that Roga draws itself ([decision 10](../../docs/decisions/0010-our-own-tabs-in-one-window.md)). It isn't part of the app. [Decision 13](../../docs/decisions/0013-repositories-in-a-sidebar.md) later replaced the tabs with a sidebar, so this preview shows the earlier layout, and [docs/main-window.md](../../docs/main-window.md) describes the current one. The layout here follows the Claude app:

- The repository tabs share the top row with the traffic lights, and nothing sits above them.
- Every section below is a plain rectangle with its own header. A segmented switch or a title goes on the left of the header, and commands go on the right.
- History is on top. The selected commit and its diff are below it, and the navigator with worktrees, branches, remotes, tags and stashes is on the right.

The commit list and the diff are quick SwiftUI stand-ins. The app will use an `NSTableView` (decision 7) and a TextKit 1 text view (decision 9). The graph column is a placeholder line, and the search, filter and "more" buttons don't do anything yet.

## Running it

```bash
prototypes/main-window/run.sh --open-all
```

The script builds the preview, wraps it in an app bundle, and opens these repositories as tabs:

- the demo repository with agent worktrees in `bench-repos/agents-demo`, which `prototypes/window-tabs/make-demo-repo.sh` creates
- this repository
- the Linux and git clones in `bench-repos/`, if they exist

Without `--open-all`, macOS restores the window's tabs from the last session, and an empty window lists the repositories to choose from.

## Things to try

- Switch tabs by clicking them, with Control-Tab, or with Command-1 to Command-9.
- Drag a tab to reorder it, and close it with its close button or Command-W.
- Open another repository with Command-T or the plus button.
- Right-click a tab to close other tabs or move the tab to a new window.
- In `agents-demo`, click a worktree in the navigator to switch to it. Then open Changes to see its uncommitted files, or right-click the worktree to open it in a new tab.
- Move the pointer over a navigator section or a worktree to see its commands, which replace the count shown at rest.
- Hide and show the navigator with the button at the right end of the tab bar.

## What it showed

- Putting the tab strip in the title bar row means hiding SwiftUI's title bar and moving the traffic lights down so they're centered in the taller bar. The window lays out its title bar again when it resizes, so the buttons have to be moved again each time.
- A tab that Roga draws needs an explicit accessibility action. Without one, VoiceOver and other accessibility clients can see a tab but can't select it.
- Paths passed as launch arguments make AppKit treat the launch as a request to open files, and SwiftUI then doesn't open its first window. If Roga ever gets a command-line launcher, such as `roga .`, it has to handle open requests itself.
- Each window can save its own tabs with `@SceneStorage`, and macOS restores them with the window.
- Keeping hidden tabs alive kept switching instant, even with Linux open. The preview does it with a `ZStack`, and the app will use a container view controller, as [ARCHITECTURE.md](../../ARCHITECTURE.md#windows-and-tabs) describes.
