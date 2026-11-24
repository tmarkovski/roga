# Hooks picture

Boards for making setup's Hooks screen fit above the lane along the bottom of setup's window ([decision 69](../../decisions/0069-set-roga-up-in-the-whole-window-the-first-time-it-runs.md)). They're on the Hooks picture page of the design canvas [yaga layout options](https://claude.ai/artifact/4WQVua6gwKqSBoiRdf2FhX#page-hookspicture), and [`boards.py`](boards.py) draws every board, borrowing the window and the lane from [`../setup-lane/boards.py`](../setup-lane/boards.py).

On a first run, with the hooks in neither agent, the Hooks screen was about 725 points tall, and the window has about 645 above the lane, so its buttons sat under the lane until it scrolled. Most of that was the picture of the sidebar's marks, 284 points of a group's label, a repository, its three worktrees and two repositories after them, one over another.

The page draws today's screen, the three worktrees across at the column's width (A), across and 800 points wide, past the column on each side (B), and A in the dark appearance. Across, each worktree sits on a piece of the sidebar's panel of its own, with what its mark means under it, and the repository rows around them go. The picture is half as tall.

## Regenerating the boards

Read `project/canvas.json` from the canvas into a folder first, so that the merge starts from what's live, then:

```bash
uv run docs/design/hooks-picture/boards.py --out <folder> --canvas <folder>/project/canvas.json
```

It writes the `Hk-*.dc.html` boards into `<folder>/project/` and replaces the Hooks picture page's boards and notes in that `canvas.json`, leaving every other page alone.

## Built

B was built on November 24, 2026, as `MarksPreview(layout: .across)` in [`MarksPreview.swift`](../../../RogaKit/Sources/RogaUI/Agents/MarksPreview.swift). At A's 196 points, the waiting worktree's line faded out at "git", the part that says what's wanted. B gives each worktree 256 points, and a test checks that every line fits whole with how long it's been. Settings › Agents keeps the picture one over another, where there's room for it.
