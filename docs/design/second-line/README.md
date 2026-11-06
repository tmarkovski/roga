# Second line

Boards for a second line under a sidebar row, which says what an agent is doing or what a worktree stopped partway through. They're on the Second line page of the design canvas [yaga layout options](https://claude.ai/artifact/4WQVua6gwKqSBoiRdf2FhX), and [`boards.py`](boards.py) draws every board.

The page compares today's one-line rows, two lines on every row (A), a second line only while there's something to say (B), and B with the mark left before the count (B2), in light and dark. It also has a sheet of what B's line says in each state, and a clickable board that simulates agents so the rows can be seen moving. We chose B, and it's built as [decision 48](../../decisions/0048-a-second-line-under-a-sidebar-row-while-theres-something-to-say.md) describes. The code in `Sidebar.swift` is what counts now, and the boards only show how it was chosen.

## Regenerating the boards

```bash
uv run docs/design/second-line/boards.py <folder>
```

It writes the six `SL-*.dc.html` files into `<folder>/project/`, and prints each board's size and how many points the list needs in each layout. Publish the files that changed into the canvas's `project/` folder.

[`index_entries.py`](index_entries.py) writes the text edits that added the page, its boards and its notes to the canvas's `project/canvas.json`. They're only needed again if the page is removed, or its layout or notes change.
