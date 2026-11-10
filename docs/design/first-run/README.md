# First run

Boards for what Roga asks the first time it runs: which Git to use, whether to use agents and which copies, whether to install their hooks, and automatic updates. They're on the First run page of the design canvas [yaga layout options](https://claude.ai/artifact/4WQVua6gwKqSBoiRdf2FhX), and [`boards.py`](boards.py) draws every board, borrowing the styles, the window and the rows of [`../settings/boards.py`](../settings/boards.py).

The whole-window setup on the page's first rows is built, as [decision 65](../../decisions/0065-set-roga-up-in-the-whole-window-the-first-time-it-runs.md) records, in [`RogaKit/Sources/RogaUI/Setup`](../../../RogaKit/Sources/RogaUI/Setup). The GitHub step and the first draft's sheets aren't. The boards show what this Mac had on November 9, 2026, read with each program's `--version`.

## Regenerating the boards

Read `project/canvas.json` from the canvas into a folder first, so that the merge starts from what's live, then:

```bash
uv run docs/design/first-run/boards.py --out <folder> --canvas <folder>/project/canvas.json
```

It writes the `FR-*.dc.html` boards into `<folder>/project/` and replaces the First run page's boards and notes in that `canvas.json`, leaving every other page and the page that opens first alone. Boards that the page had and this run no longer draws are listed at the end, so they can be removed when the files are published.

To try the boards before publishing, read `artifact-type/dc-runtime.js` from the canvas, save it as `support.js` beside the boards, and serve the folder. Each board then runs in a browser as it does on the canvas, and `FR-Try` can be clicked through.

## Decided

- **Setup takes the whole window, not a sheet.** The first draft was a sheet over the empty window, drawn like Roga's dialogs ([decision 29](../../decisions/0029-dialogs-that-say-what-happens-and-show-the-command.md)), with Settings rows for content. It read as an interruption rather than an arrival, so setup now takes over the one window and the window becomes the app when it's done. The sheet stays on the page's last row. Decided on November 9, 2026.
- **Linear's layout, Conductor's approach, Arc's voice, and our house.** One centered column with a big answer and one dark button, as Linear lays out its setup. Roga looks around first and only stops you where there's a choice or something's missing, as Conductor checks for its tools. Short, warm sentences, as Arc writes. The house walks along a floor at the bottom as you go and waddles while Roga is busy, drawn the way decision 21 draws it, and it stands still for anyone who asked for less motion. Decided on November 9, 2026.
- **A program is a row, and its copies are a menu on that row.** Git, Claude Code and Codex each get the same row: the name, the version, a check mark for having been found, and the path. A button at the row's right names where that copy is from and opens a menu of every copy Roga found, with why it would or wouldn't run each. The second draft had tiles with a "Change" link that opened a list under both tiles, away from the one it belonged to. Settings uses the same row.
- **A step you can decline is answered with its buttons.** Agents ends in Don't Use Agents and Use Agents, and Hooks in Not Now and Install Hooks. The second draft had a switch on each agent and a line of text under them for not using any, which made one decision look like three. Leaving one agent out is Don't Use Codex in that agent's menu.
- **The Hooks screen says why, then what, then how.** A picture of three sidebar rows, each with a line out to what its mark means, so it reads as a picture. Then a sentence that says what Install Hooks does. Then one card that names where the plugin goes and ends in the exact commands. After Install, the commands give way to what happened in each agent.
- **Ready has two labeled groups.** What you chose, with a mark for each line and Change to go back to that step, and One more thing, for the update switches.

The second draft's Agents, Hooks and Ready screens were redrawn on November 9, 2026, after going through the clickable board showed where they were hard to follow.

## The flow

There's no ×, because every step comes filled in and the dark button is the quick way through.

| Screen | What it does | Drops out when |
| --- | --- | --- |
| Welcome | The house, the wordmark, what Roga is for, and Get Started | Never |
| Looking around | Reads the login shell's `PATH` and asks each program for its version, as it happens | Never |
| Git | Says which Git Roga will use, with a menu of the others on its row | Never, and it stops you if there's no usable Git |
| Agents | Asks whether to use the agents Roga found, each with a menu of its copies | Never |
| Hooks | Shows what the sidebar's marks mean, says what Install Hooks does, and shows each agent's status and the commands | Agents aren't used, or none were found |
| GitHub (later) | Whether to use the account `gh` is signed in to | The GitHub CLI isn't installed |
| Ready | What you chose, with Change for each line, and the update switches | Never |

## What was built, and where it differs from the boards

Roga already found git and each agent, had the rule for which copy wins, the minimum versions, a switch for each agent, the hooks' commands and their status, both update switches, the house and the sidebar's marks. Setup added:

- A list of every git and of every copy of an agent, with why Roga can or can't use each (`GitInstallation.survey` and `AgentInstallation.survey`).
- A saved choice of git (`GitPreferences.programKey`), which `GitProvider` uses or reports.
- The row with its menu (`ProgramRow`), in setup, in Settings › Git, and as the Program row's button on each agent's page, where it replaces Choose… and Use the One Roga Finds.
- The setup window (`SetupView`), its state (`SetupModel`) and a saved flag for setup being done, which also skips setup for anyone who already has repositories.

The app differs from the boards in a few places, each because the board was wrong about the app:

- **A copy with no better name is called by its folder.** The boards call `~/.local/bin/claude` Your PATH, but the copies under nvm are in `PATH` too. The menu's last line says which one a terminal runs.
- **The Hooks picture has the count before the mark,** as the sidebar has drawn a row since [decision 58](../../decisions/0058-the-mark-under-the-menus-button-and-the-count-before-it.md). The board has them the other way round.
- **There's no single switch for not using agents.** `FR-Settings-Agents` draws one. Don't Use Agents turns off each agent's own switch instead, found or not, so Settings › Agents is as it was.
- **A git chosen in Settings takes over the next time Roga opens,** and Settings says so. The repositories in the sidebar are opened with one git and keep it.
- **A screen that leaves no room for the floor goes without it,** and scrolls if it has to, so the house never stands on a button. With Codex run from inside the ChatGPT app, its path makes the Hooks screen's commands several lines longer than the board's.
- **Looking's heading changes** to "Roga looked around your Mac" once it's done, which it often is by the time someone gets there.

Going through the built setup on November 9, 2026 showed two things the boards got wrong, which the app now does differently:

- **The buttons are at the column's edges, not in its middle.** The boards center each screen's buttons, so the dark one was somewhere else on every screen, depending on how many others there were and how long their words. Back is now at the left edge on every screen after Welcome, and the rest are at the right in one order: what helps, then the answer that declines, then the one that goes on, at one width. Git's "no usable Git" screen has Back too, and Choose Another… is a gray button like Look Again.
- **Every heading is one line, and the head is one height.** The Git board's heading names where the git is from, which ran to two lines for the Command Line Tools and pushed everything under it down. The heading is now "Roga will use Git 2.54.0", and the row's button names where it's from. The sentence under a heading has room for two lines whether it needs them or not, so each screen's card starts in the same place.

Two more things came from the same pass. Open Roga is in the house's orange, where the boards have it dark like the others. And setup moves: a screen comes in from the side setup is moving toward, Welcome's parts and Ready's marks come in one after another, and a row on Looking turns from a ring into a check as its answer arrives.

## Still to decide

- **Which Codex is recommended.** Today's rule is newest wins, which here picks ChatGPT's `0.167.0-alpha.3.2` over Homebrew's `0.166.0`. It may be better to skip prerelease versions.
- **GitHub.** Listing repositories from `gh` is parked, and `VISION.md` says Roga isn't a hosting client. The step only holds its place and shouldn't ship in the first version.
