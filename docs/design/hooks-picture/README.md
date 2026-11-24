# Hooks picture

Boards for making setup's Hooks screen fit above the lane along the bottom of setup's window ([decision 69](../../decisions/0069-set-roga-up-in-the-whole-window-the-first-time-it-runs.md)). They're on the Hooks picture page of the design canvas [yaga layout options](https://claude.ai/artifact/4WQVua6gwKqSBoiRdf2FhX#page-hookspicture), and [`boards.py`](boards.py) draws every board, borrowing the window and the lane from [`../setup-lane/boards.py`](../setup-lane/boards.py).

On a first run, with the hooks in neither agent, the Hooks screen was about 725 points tall, and the window has about 645 above the lane, so its buttons sat under the lane until it scrolled. Most of that was the picture of the sidebar's marks, 284 points of a group's label, a repository, its three worktrees and two repositories after them, one over another, and the commands under the agents.

The page has two tries, newest first.

- **Side by side, or trimmed.** Neither has the commands on the screen. Show Commands after the sentence opens them in a popover. S puts a glimpse of the sidebar, with just the repository and its three worktrees, on the left, and what Install Hooks does with each agent's status on the right. T keeps the picture with its lines out to what each mark means, trimmed to the same rows, over the agents. Both stay in the column. The page draws both on a first run and with the longest rows an agent can have, where another copy of Roga installed the hooks, then Show Commands open and S in the dark appearance.
- **The picture across.** The three worktrees across at the column's width (A) and 800 points wide (B), each on a piece of the sidebar's panel of its own, with what its mark means under it, and today's screen before it.

## Regenerating the boards

Read `project/canvas.json` from the canvas into a folder first, so that the merge starts from what's live, then:

```bash
uv run docs/design/hooks-picture/boards.py --out <folder> --canvas <folder>/project/canvas.json
```

It writes the `Hk-*.dc.html` boards into `<folder>/project/` and replaces the Hooks picture page's boards and notes in that `canvas.json`, leaving every other page alone.

## Built

B was built first, on November 24, 2026. Across, the picture was half as tall, but going through it in the app showed a screen that was still busy, mostly from the commands, and three tiles that read less like the sidebar than the picture one over another did.

S replaced it the same day, as `MarksPreview(layout: .glimpse)` in [`MarksPreview.swift`](../../../RogaKit/Sources/RogaUI/Agents/MarksPreview.swift) beside the agents' card in [`SetupScreens.swift`](../../../RogaKit/Sources/RogaUI/Setup/SetupScreens.swift). With the longest rows, T ran about 40 points under the lane, and S still fits with room to spare. S loses the lines out to what each mark means, since there's no room for them beside the glimpse, but each worktree's second line says what its agent is doing, and a test checks that every one fits whole with how long it's been. Where the app differs from the boards:

- **The rows are laid out alike.** On this Mac, Claude Code's long status went under its name and Codex's, with a shorter name, fit beside it. So the card measures every row, and when any status doesn't fit beside its agent's name, every status goes under.
- **Show Commands is a button under the sentence,** not a link inside it, so that it's a button to the keyboard and VoiceOver, and its popover points at it. The commands run along the popover's bottom edge, edge to edge, as the agents' popover has its command, and Escape closes it.

Settings › Agents keeps the picture one over another, with the rows around it and the lines out to what each mark means, where there's room for it.
