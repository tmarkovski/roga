# 41. Show what agents are doing from their hooks, and write commit messages with their CLIs

Accepted on 2026-11-06. Partly superseded by [decision 46](0046-turn-the-ring-of-an-agent-at-work.md), which turns the ring that marks an agent at work, and by [decision 47](0047-say-what-an-agent-is-doing-in-a-line-the-helper-makes.md), which has the helper send a short line about what the agent is doing, made from a tool's input or its reply, and shows it in the mark's tooltip and the worktree menu, and by [decision 48](0048-a-second-line-under-a-sidebar-row-while-theres-something-to-say.md), which moves a row's mark to the start of a second line that says what the agent is doing, and by [decision 51](0051-marks-at-the-right-of-a-sidebar-row-and-names-that-fade.md), which moves it to the right of the row, before the count, and drops the button for a new window from a worktree's row, and by [decision 68](0068-mark-an-agents-commands-with-an-orange-line-rather-than-sparkles.md), which replaces the Generate button's sparkles with an orange line and the word Rewrite. The rest of this decision still holds. This adds the agent's line that [decision 40](0040-the-repositorys-name-opens-a-menu-of-its-worktrees.md) left a place for in the worktree menu, and the marks that [decision 16](0016-a-rail-of-organizations-in-the-sidebar.md) said would wait for hooks. It adds a second program to the bundle that [decision 11](0011-thin-xcode-project-and-a-local-package.md) describes, a shortcut to the table in [decision 30](0030-stage-and-commit-beside-history.md), and a third kind of command to the blocks of [decision 29](0029-dialogs-that-say-what-happens-and-show-the-command.md).

## Context

People run coding agents in linked worktrees, several at once, and come back to Roga to see which ones need them. Nothing in the sidebar said so. The same people already have the agents' command-line tools installed and signed in, so those tools can write a commit message from the staged diff without Roga holding an API key of its own.

The Settings canvas drew both: marks beside the sidebar's rows, the Agents page, a page for each agent, the Commit page's Generate section, and the Generate button in the commit box with its popover. We looked at how other Git clients tell what an agent is doing. GitKraken relays the agents' hooks to the app through a helper, which is the part we copied. Others guess from file changes or from the terminal's output, which says nothing about an agent that's waiting for permission.

This version covers Claude Code and Codex. Other agents, custom commands, the Work view, reordering rows by what needs you, notifications, and answering an agent's permission request in Roga are left out.

## Decision

### Status comes from the agents' hooks

**Roga never guesses from file changes.** Each agent tells Roga what it's doing through hooks that Roga installs, as a plugin called `roga-hooks` in a marketplace called `roga`. The marketplace is a folder, `plugins/` in Roga's own folder in Application Support. Roga writes it each time it launches, and adds it to an agent only when someone presses Install…, on the Agents page or on the agent's own page. The dialog shows the exact commands first, and when Roga found the other agent without its hooks, it offers to install them there too:

| Agent | Install | Remove |
| --- | --- | --- |
| Claude Code | `claude plugin marketplace add <folder>`, `claude plugin install roga-hooks@roga --scope user`, `claude plugin update roga-hooks@roga --scope user` | `claude plugin uninstall roga-hooks@roga --scope user`, `claude plugin marketplace remove roga` |
| Codex | `codex plugin marketplace add <folder>`, `codex plugin add roga-hooks@roga` | `codex plugin remove roga-hooks@roga`, `codex plugin marketplace remove roga` |

Codex runs a hook only once the person has trusted it: when Codex starts in a terminal, or with `/hooks`, or with Review hooks or Settings › Hooks in the ChatGPT app. It keeps that trust in `config.toml` after a remove. Roga reads `config.toml` as text to tell whether the hooks are trusted, but never writes to it. Codex ties the trust to a hash of the plugin's files, so any change to them, including a new `HookPlugin.version`, makes people trust the hooks again. That's why the launcher, the one file that knows where the app is, sits outside the plugin, and why the plugin's files come out the same bytes every time, with no timestamps, and are written only when those bytes change. Roga's check finds only that some trust is recorded, so it can't tell when that trust has gone stale.

**Every hook runs one small helper, `roga`, inside the app.** It's at `Roga.app/Contents/Helpers/roga`, and each hook runs it through a launcher script, `bin/roga-hook` in Roga's folder in Application Support, as `roga-hook hook --host claude --event PreToolUse` with the event's JSON on standard input. The launcher points at the copy of Roga that's listening, so the hooks keep working when the app moves, and a launcher whose app is gone reads its input and exits. The helper:

- prints nothing and always exits with status 0, because Claude Code adds a hook's output to what the model reads, and both agents show an error for any other status;
- keeps only the session, its folder, the tool's name, which subagent sent it, why a session started, and the few fields that say why it stopped or waits, and never forwards a prompt or a tool's input;
- walks up past shells and wrappers to the agent's process, and sends its ID and start time;
- sends one line of JSON to `hooks.sock` in Roga's folder in Application Support, next to the launcher's `bin` folder, giving up after a fifth of a second to connect and as long again to write, so an agent never waits on Roga;
- does nothing when `ROGA_GENERATING=1` is set, which Roga's own Generate runs set, so that they never show up as an agent at work.

Its bundle ID comes from the app it's inside, so a copy of Roga with another bundle ID hears only its own helper. Only one copy with the same ID listens, the one holding `hooks.lock`. Another copy says on the Agents page that it can't show the marks, and only the copy holding the socket points the launcher at itself.

**The events become one of four phases for each session**, which `AgentSessions` keeps:

| Phase | From |
| --- | --- |
| Working | `UserPromptSubmit`, `PreToolUse`, `PostToolUse` and the other events of a turn, and `Stop` while background tasks still run |
| Waiting for you | `PermissionRequest`, `Elicitation`, Claude Code's `Notification` of a permission prompt or an elicitation dialog, and `PreToolUse` of `AskUserQuestion`, `ExitPlanMode` or Codex's `request_user_input` |
| Finished | `Stop`, or `StopFailure`, which is finished with a failure |
| Idle | `SessionStart`, unless compacting sent it; Codex's `Interrupt`; and Claude Code's `idle_prompt` notification, but only while the session still shows working, as after Esc |

`SessionEnd` removes the session. A subagent's own events don't change its parent's phase, with two exceptions: a subagent starting shows the parent as working, since its turn is still going, and a subagent's event is enough to show a session Roga hadn't heard of as working. An event that ran before the newest one Roga has heard, but reaches it later, doesn't undo it. One that's more than 30 seconds older is taken as new, because the Mac's clock must have been set back. When several sessions are in one worktree, waiting beats working, and working beats finished.

Codex ignores the events it doesn't know yet: `SessionEnd` before 0.145 and `Interrupt` before 0.150. On an older Codex, a session ends only when its process exits, and Esc never makes it idle. Each hook has 5 seconds to run, and Codex's `SessionEnd` and `Interrupt` have 3.

**Apart from what the hooks themselves say, stale sessions are cleared two ways.** A session ends when its agent's process exits, which Roga watches with a dispatch source rather than polling. And Roga asks `claude agents --json` what's running whenever it finds Claude Code's hooks installed, at launch and again after Look Again or Install, and for a Claude Code session that has shown working for 90 seconds with no event, since pressing Esc sends none. A session Roga knows only from that answer may have started before the hooks were installed, and such a session never loads them, so Roga asks about it at every check while it waits, and it becomes idle once the answer stops listing it. When Claude Code starts a new session in the same process, after `/clear` or `/resume`, the one it replaced ends too.

Look Again runs each copy of each agent to read its version, and each look at the hooks' status runs each agent's `plugin list`, so nothing refreshes them on a timer, and Settings checks the hooks only once each time it's opened.

### The marks

**A mark sits on the right of a row, before the count of uncommitted files,** and stays while the pointer is over the row, with the row's commands after it. It never moves a row or changes its width, and on a narrow sidebar the branch's name gives way first.

- **Working** is a gray ring with a quarter of it in Roga's orange, starting at the top. It stands still, as the canvas draws it.
- **Waiting for you** is Lucide's `circle-alert` in amber, not the board's triangle, because [decision 28](0028-show-a-worktree-thats-stuck-partway.md)'s red triangle means conflicts. It's drawn at 0.88 of its box, so that it looks as big as the ring.
- **Finished** is a blue dot, until someone sees it: by selecting the worktree, because it finished while its window was in front showing it, or because its window came to the front showing it. It also goes when that agent starts another turn or its session ends, as when someone quits Claude Code. What has been seen is kept only until Roga quits.

A repository's row shows its main worktree's mark, and the row for hidden worktrees shows the most urgent of theirs. The mark's tooltip says which agent, or how many when there are several, as in "2 agents are working", and from a minute on, for how long, as in "Claude Code is working, for 6 minutes". A finished mark doesn't say how long. VoiceOver reads it as part of the row. In the worktree menu, the agent comes first on the second line, as in **Agent working · 6 min**, in amber while it waits.

**Show agents in the sidebar,** on the Agents page, hides both the marks and the menu's line, so that the menu doesn't show what was turned off.

### Generate

**The Generate button sits inside the message box, at its bottom right.** It reads Generate with sparkles while the box is empty, and shows the icon alone once there's text, which the agent then starts from. Its chevron opens a popover to pick the agent, its model and its effort, which shows the exact command and remembers the choice. ⌥⌘L in the Changes menu does the same, and picking an agent from Generate With there makes it the one Generate uses and writes the message at once. While the agent writes, the box shows gray bars, a counter and Stop. Then the message replaces the box's text, with a note that says who wrote it and how long it took, and Undo. If the staged files changed while it wrote, the note says so, and editing the subject the agent wrote removes the note and its Undo. A failure keeps the text and says in one sentence what went wrong, with what the agent printed folded under it, then Try Again and Agent Settings…. For failures Roga knows, such as not being signed in, a usage limit, or a model that needs a newer Codex, Roga writes that sentence itself, and otherwise it's the first line the agent printed.

**The run belongs to the worktree, not to one window.** A commit box made again for the same worktree while an agent writes, because a window closed and another opened it, takes the run over, Amend included. Amend Commit and Generate both wait until HEAD's message is in the box. Quitting Roga stops every agent that's writing, and Run a Test too.

**What goes to the agent:** the list of staged files, the staged patch cut to 32,000 bytes, the branch's name, the draft when there is one, the instructions, and with Match the repository's style, the last 20 commit subjects. The patch leaves out lockfiles, generated and binary files, unless they're all that's staged, and then, only while it's too long, the ends of very long lines, files too long to show in part, and the last hunks of the file with the most, each marked where something was left out. With Amend ticked, the patch is compared with the first parent of `HEAD`, so the message covers the whole amended commit, and Generate works with nothing staged. The diff goes on standard input. The default instructions ask the agent to follow the repository's own style rather than a fixed rule such as "always a body".

**The agent runs with as little as it needs.** The agent's page lists the flags that keep the run small, each with its reason, and its command block shows the rest:

| Agent | Command |
| --- | --- |
| Claude Code | `claude -p --safe-mode --setting-sources user [--model] [--effort] --tools= --no-session-persistence --output-format json --system-prompt <instructions> [extra arguments] -- <task>` |
| Codex | `codex exec --ephemeral --sandbox read-only --color never --skip-git-repo-check --disable hooks --disable plugins --disable apps --disable shell_tool -c notify=[] -c web_search=disabled -c mcp_servers.<name>.enabled=false … [-m] [-c model_reasoning_effort=…] [extra arguments] <instructions and task>` |

`--safe-mode` turns off Claude Code's hooks, plugins, skills, MCP servers and CLAUDE.md while its sign-in still works, which `--bare` doesn't. `--setting-sources user` leaves out the repository's own `.claude` settings, which `-p` would otherwise use without asking whether to trust the folder. Codex has no flag that turns off every MCP server, and they run outside its sandbox, so Roga reads their names in `config.toml` just before each run and turns each off by name. It never guesses a name, because Codex refuses to start when `-c` names a server it doesn't have. Generate runs at normal priority, since someone waits for it. Each run of the agent stops after its time limit, 60 seconds unless changed. When a reply's subject is empty or ends in an ellipsis, Roga asks once more, so one Generate can take up to twice the limit.

### Finding the agents, and Settings

**Roga looks for each agent in the login shell's `PATH`, then where its installers put it,** such as `~/.local/bin/claude` and the copy of `codex` inside the ChatGPT app. Claude Code takes the first usable one in `PATH` order, as git does ([decision 3](0003-use-the-users-git.md)), since it keeps itself up to date. Codex takes the newest, because Codex's server refuses old versions for new models. Claude Code needs 2.1.169 for `--safe-mode`, and Codex needs 0.131.0, the first that runs a plugin's hooks and asks to trust them. Someone can choose the program instead, and Roga looks again whenever it changes.

**Settings has an Agents page and a page for each agent,** and the Commit page gets a Generate section. The Agents page lists Claude Code and Codex, each with where Roga found it and its version, or why it can't use it, and a Use switch, with Look Again above them. Under Working status come each agent's hooks with Install… or Remove…, the marks' switch and their legend. An agent's page has Use, its program, model, effort, extra arguments and time limit, the flags that keep the run small and why, Run a Test, which writes a message for a small sample diff in a folder of its own, and its hooks. Model and effort are kept once for each agent, so the popover, the Commit page and the agent's page all change the same values. A hooks install or remove that fails says so in the agent's own words, in every window's Settings, until it no longer applies or someone presses Look Again.

Commands that aren't git's, like the agents', show in the same dark blocks as git's, with the program's path written out when the name alone wouldn't find it.

## Consequences

- Claude Code has to be signed in at the terminal, with `claude auth login`, before Generate works with it. One that isn't fails, and the card says to run `claude auth login` in Terminal.
- Codex's hooks do nothing until someone trusts them once in Codex, and again whenever the plugin's files change. The Agents page says so.
- Codex's Install fails when another copy of Roga already added a marketplace called `roga` from another folder. Press Remove… first, which the Agents page offers in that case, and then Install…. Claude Code's Install takes the other copy's over.
- `claude agents --json` lists only interactive sessions, so a `claude -p` that another tool runs, or one with another `CLAUDE_CONFIG_DIR`, ends only by its process exiting or by its hooks.
- MCP servers that a trusted project sets up in its own `.codex/config.toml` stay on, because Roga reads only the `config.toml` in Codex's home folder. So do servers whose names aren't plain TOML keys, because `-c` splits its key at every dot and can't name them.
- Stopping the agents when Roga quits is best effort. The signal goes out on the process's own queue, which can lose the race with the app's exit, and then the agent runs on until its reply finds the pipe closed.
- Settings says when it last heard from an agent in whole minutes, and what it shows can be up to 30 seconds behind, so that it doesn't redraw for every tool an agent runs.
- The socket's path can be at most 103 bytes, since a socket address holds 104 with the zero that ends it. A home folder over about 50 characters long would stop the marks, and the Agents page would say why.
- The helper is a second program that has to be signed and notarized with the app. The release script stops before notarizing when it's missing or signed differently, and `roga --version` says which app it came with.
