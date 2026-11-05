# Settings

Wireframes for a larger Settings window with a sidebar of pages, laid out like the Claude app's own settings and styled like Roga's dialogs ([decision 29](../../decisions/0029-dialogs-that-say-what-happens-and-show-the-command.md)). They're on the Settings page of the design canvas [yaga layout options](https://claude.ai/artifact/4WQVua6gwKqSBoiRdf2FhX), and [`boards.py`](boards.py) draws every board. Nothing here is built yet.

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
| Commit | The long first line, generating messages with an agent, the Commit button, signing, discarding | The 72-character mark and asking before discarding many files, both as fixed behavior |
| Agents | Command-line agents Roga found, and their hooks for working status | Nothing |
| Advanced | Commit-graph files, the command log, resetting settings | Keeping commit-graph files up to date |

## Agents

Roga finds command-line agents (Claude Code, Codex, Cursor Agent, Gemini CLI, Copilot CLI) in the login shell's `PATH`, the way it finds git, and a custom command covers anything that reads standard input and prints a message, such as Ollama.

**Generating a commit message** pipes the staged diff to one agent with its tools off, in the worktree's folder, and shows the command it runs:

```bash
git diff --cached | claude -p --model haiku --effort low --tools "" --no-session-persistence "Write a commit message for…"
git diff --cached | codex exec --sandbox read-only --ephemeral -c model_reasoning_effort=low "Write a commit message for…"
```

The Generate button sits inside the message box. A click uses the agent, model and effort picked last time, the arrow beside it opens a popover to change them, and ⌥⌘L does the same as the click.

**Working status** comes from the agents' hooks, never from watching files. Roga would ship a plugin and install it with each agent's own commands, the way GitKraken installs its `gitkraken-hooks` plugin:

```bash
claude plugin marketplace add ~/Library/Application\ Support/sh.roga.app/plugins
claude plugin install roga-hooks@roga
codex plugin marketplace add ~/Library/Application\ Support/sh.roga.app/plugins
codex plugin add roga-hooks@roga
```

Each hook runs `roga hook --host <agent>`, a small helper that tells Roga the event and the folder, returns at once, and does nothing while Roga is closed. Roga ignores folders that aren't in its sidebar.

## Still to decide

- **A window or a sheet.** The boards draw a window shaped like a dialog. Settings apply to the whole app and Roga can have several windows, so its own window, opened with ⌘,, fits better than a sheet attached to one of them.
- **Which proposals to keep.** Open in Editor and Open in Terminal, text size and date formats would each need work outside Settings first.
- **Answering permission requests in Roga.** GitKraken offers it. It makes a hook wait for Roga, so the boards draw it off.
- **Where the agent marks go.** The legend uses the sidebar marks drawn earlier for the Work view, which is on hold until these hooks exist.
