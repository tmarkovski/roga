# Commit box

Boards for putting the message box's buttons inside the text box's border, on one row under the text, the way a chat box does. They're on the Commit box page of the design canvas [yaga layout options](https://claude.ai/artifact/4WQVua6gwKqSBoiRdf2FhX), and [`boards.py`](boards.py) draws every board.

They start from `CommitBox.swift` as it is on main, where the box is three bands: a heading with Amend, the text box with Generate in its corner, and a footer with ⌘↩ and Commit. At the default width of 320 points an empty box takes 146 points, and its text gets 29 of them.

The page has today's box, then three options drawn in the same moments at 320 points with the files above them, so the room each gives back to the list shows:

- **A** keeps the heading and moves Amend into the row as a toggle, beside Generate, with Commit on the right. Three controls don't fit at 320 points with their full names, so Generate can't name the agent.
- **B** has Generate on the left and Commit on the right, and Commit's chevron opens the Changes menu's own group: Commit, Commit and Push, and Amend. The heading goes, and a chip at the top of the box shows only when the commit isn't an ordinary one, such as an amend, a merge or a rebase. Empty, it's 118 points.
- **C** uses a round button that sends, with its words beside it in gray. It's the most like a chat box, but Commit's words, such as Stage All and Commit or 2 Conflicts Left, end up as a caption.

After that, B is drawn in every state the box has today, in both appearances, and Try it puts today's box and B side by side with one message between them.

## Decided

- **B, without the rounded card.** Decided on November 23, 2026, and built as [decision 98](../../decisions/0098-buttons-in-a-row-under-the-message.md), whose code is what counts now. Trying B in the app showed that the card repeats the edge the line over the box and the panel's sides already give it, so the box has no border of its own, the light that says an agent is writing runs along that line, and the box is 100 points tall when empty rather than the canvas's 118. The canvas still draws B in a card.

## Still to decide

- **The branch for an ordinary commit.** B leaves it to the branch row at the top of the window. A quiet first line in the box would cost about 26 points.
- **Who wrote the message.** The old line under the box said which agent and model wrote it and how fast. B has that in Undo's tooltip only.

## Regenerating the boards

Read `project/canvas.json` from the canvas into a folder first, so that the merge starts from what's live, then:

```bash
uv run docs/design/commit-box/boards.py --out <folder> --canvas <folder>/project/canvas.json
```

It writes the `Cb-*.dc.html` boards into `<folder>/project/` and replaces the Commit box page's boards and notes in that `canvas.json`, leaving every other page alone. Publish those files to the canvas.
