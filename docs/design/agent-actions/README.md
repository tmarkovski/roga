# Agent actions

Boards for how to mark a command that one of your own agents carries out, in place of the sparkles. They're on the Agent actions page of the design canvas [yaga layout options](https://claude.ai/artifact/4WQVua6gwKqSBoiRdf2FhX), and [`boards.py`](boards.py) draws every board.

The page compares today's sparkles with six treatments, in the message box, the diff's header and a dialog, in light and dark. It also has a sheet of each treatment's states, a clickable board for judging the motion, and every place the sparkles were, before and after. We chose B, the line with a light that runs around it, and it's built as [decision 68](../../decisions/0068-mark-an-agents-commands-with-an-orange-line-rather-than-sparkles.md) describes. The code in `AgentOutline.swift` is what counts now, and the boards only show how it was chosen.

## Regenerating the boards

```bash
uv run docs/design/agent-actions/boards.py <folder>
```

It writes the five `Ag-*.dc.html` files into `<folder>/project/` and prints each board's size. Publish the files that changed into the canvas's `project/` folder.
