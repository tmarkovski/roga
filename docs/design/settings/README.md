# Settings

Wireframes for a Settings window with a sidebar of pages, laid out like the Claude app's own settings and styled like Roga's dialogs ([decision 29](../../decisions/0029-dialogs-that-say-what-happens-and-show-the-command.md)). They're on the Settings page of the design canvas [yaga layout options](https://claude.ai/artifact/4WQVua6gwKqSBoiRdf2FhX), and [`boards.py`](boards.py) draws every board.

Settings is built as a sheet, in [`SettingsSheet.swift`](../../../RogaKit/Sources/RogaUI/Settings/SettingsSheet.swift) and [`SettingsControls.swift`](../../../RogaKit/Sources/RogaUI/Settings/SettingsControls.swift), drawn to the boards' measurements and colors rather than with the system's lists and forms. It has the options Roga already had, on Appearance, Git and Advanced, and the agents' pages that [decision 41](../../decisions/0041-agents-status-from-their-hooks-and-messages-from-their-clis.md) added: the Commit page's Generate section, the Agents page, and a page for Claude Code and for Codex. The other pages and every other proposal on the boards wait until they're decided.

## Regenerating the boards

Read `project/canvas.json` from the canvas into a folder first, so that the merge starts from what's live, then:

```bash
uv run docs/design/settings/boards.py --out <folder> --canvas <folder>/project/canvas.json
```

It writes the `St-*.dc.html` boards into `<folder>/project/` and replaces the Settings page's boards and notes in that `canvas.json`, leaving every other page and the page that opens first alone. Publish those files to the canvas.

## The pages

Rows tagged **In the app** on the boards are what today's settings window or menus already have. Everything else is a proposal, taken from what Git clients commonly offer.

| Page | What's on it | In the app today |
| --- | --- | --- |
| General | Reopening windows, the rail of organizations, the editor and terminal for Open in…, updates | The rail, from the View menu |
| Appearance | Theme, text size, the house's animations, the code font and diff options, how lists are shown | The animation speed, and the file layout, branch sort and folded descriptions from menus |
| Git | Which git runs and why one was passed over, name and email, fetching, pulling and pushing | Fetching when Roga becomes active |
| Commit | The long first line, generating messages with an agent, the Commit button, signing, discarding | The Generate section, and the 72-character mark and asking before discarding many files as fixed behavior |
| Agents | Command-line agents Roga found, and their hooks for working status | Claude Code and Codex, each with a page of its own, without Add a Command |
| Advanced | Commit-graph files, the command log, resetting settings | Keeping commit-graph files up to date |

## Agents

The boards draw more agents (Cursor Agent, Gemini CLI, Copilot CLI) and a custom command for anything that reads standard input and prints a message, such as Ollama. Roga has Claude Code and Codex, which it finds in the login shell's `PATH`, the way it finds git, and then where their installers put them. [Decision 41](../../decisions/0041-agents-status-from-their-hooks-and-messages-from-their-clis.md) has the details.

**Generating a commit message** sends the staged diff to one agent on standard input, with its tools, hooks, plugins and MCP servers off, in the worktree's folder, and shows the command it runs. The commands the boards draw are shorter than the real ones, which are in the decision:

```bash
git diff --cached | claude -p --model haiku --effort low --tools "" --no-session-persistence "Write a commit message for…"
git diff --cached | codex exec --sandbox read-only --ephemeral -c model_reasoning_effort=low "Write a commit message for…"
```

The Generate button sits inside the message box. A click uses the agent, model and effort picked last time, the arrow beside it opens a popover to change them, and ⌥⌘L does the same as the click.

**Working status** comes from the agents' hooks, never from watching files. Roga ships a plugin and installs it with each agent's own commands, the way GitKraken installs its `gitkraken-hooks` plugin:

```bash
claude plugin marketplace add ~/Library/Application\ Support/sh.roga.app/plugins
claude plugin install roga-hooks@roga --scope user
codex plugin marketplace add ~/Library/Application\ Support/sh.roga.app/plugins
codex plugin add roga-hooks@roga
```

Each hook runs `roga-hook hook --host <agent> --event <name>`, a launcher in Roga's folder in Application Support that hands the event to the `roga` helper inside the app, which tells Roga the event and the folder, returns at once, and does nothing while Roga is closed. Roga ignores folders that aren't in its sidebar.

## Decided

- **A sheet, drawn like Roga's dialogs, opened with ⌘,.** A window of its own was chosen first and built with the system's sidebar and grouped form, which looked like any Mac app's settings: blue selection, gray cards around the rows, and the system's title bar. So Settings is a sheet on the focused window, laid out like the boards: the sidebar runs the full height with the search field at its top, where the boards have the traffic lights, and the content has a title bar with the page's name and an ×, with no card around the rows. A "Settings" heading across the whole sheet was tried and dropped, since the sheet is plainly Settings already. With no Roga window open, ⌘, opens one and shows Settings on it. The boards still draw the window's traffic lights. Decided on November 5, 2026.

- **A gear at the bottom of the rail opens it too.** Without it, nothing in the window leads to Settings, and the Agents page, where the hooks get installed, needs to be found. The Claude app opens Settings from the account menu at the bottom of its sidebar, and Roga has no account, so a plain gear takes that corner, under the button for adding repositories. It isn't an organization, so it never gets the ink tile, and it stays gray while the sheet is open. It hides with the rail rather than moving to the list's header, where it would look like settings for that list. Decided on November 5, 2026.

- **Built first with only what Roga had.** Appearance has the house's animations and speed, how files are laid out, how branches are sorted and whether commit descriptions are folded. Git has fetching, and Advanced has commit-graph files. The rail of organizations stayed in the View menu, because each window keeps its own. The search field finds settings by their words across the pages. The sidebar's footer has Roga's version but no Release Notes link, because there are no release notes yet. Built on November 5, 2026.

- **The agents' pages, built for Claude Code and Codex.** The Commit page has only its Generate section. The Agents page has the agents Roga found, Look Again, each agent's hooks with Install… or Remove…, the switch for the sidebar's marks and their legend. Each agent's page has its command's settings, the flags Roga always adds and why, Run a Test, and its hooks, but no model or effort of its own beyond the ones the Commit page and the Generate popover share. Left out: other agents, Add a Command, notifications, putting the worktrees that need you first, and answering permission requests in Roga. The help under the command block changed: the board's says the agent also reads the repository's CLAUDE.md or AGENTS.md, but `--safe-mode` leaves Claude Code's out, so the help says what's turned off instead. Built on November 6, 2026.

- **The marks go on the right of a sidebar row, before the count of uncommitted files,** and stay while the pointer is over the row. The waiting mark is an amber `circle-alert` rather than the boards' triangle, because a red triangle already means conflicts ([decision 28](../../decisions/0028-show-a-worktree-thats-stuck-partway.md)). Decided on November 5, 2026.

## Still to decide

- **Which proposals to keep.** Open in Editor and Open in Terminal, text size and date formats would each need work outside Settings first.
- **Answering permission requests in Roga.** GitKraken offers it. It makes a hook wait for Roga, so the boards draw it off, and Roga leaves it out for now.
- **More agents.** Cursor Agent, Gemini CLI, Copilot CLI and a custom command are on the boards. Each needs its own way to install hooks and to run without tools.
- **Whether the boards should catch up.** They still draw the triangle, the shorter commands and the old help under the command block.
