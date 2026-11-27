# Settings

Interface wording follows [decision 72](../../decisions/0072-use-standard-interface-terminology.md). The boards retain their original labels as layout references.

Wireframes for a Settings window with a sidebar of pages, laid out like the Claude app's own settings and styled like Roga's dialogs ([decision 29](../../decisions/0029-dialogs-that-say-what-happens-and-show-the-command.md)). They're on the Settings page of the design canvas [yaga layout options](https://claude.ai/artifact/4WQVua6gwKqSBoiRdf2FhX), and [`boards.py`](boards.py) draws every board.

Settings is built as a sheet, in [`SettingsSheet.swift`](../../../RogaKit/Sources/RogaUI/Settings/SettingsSheet.swift) and [`SettingsControls.swift`](../../../RogaKit/Sources/RogaUI/Settings/SettingsControls.swift), drawn to the boards' measurements and colors rather than with the system's lists and forms. It has the options Roga already had, on Appearance, Git and Advanced, the theme, and the agents' pages that [decision 41](../../decisions/0041-agents-status-from-their-hooks-and-messages-from-their-clis.md) added: the Commit page's Generate section, the Agents page, and a page for Claude Code and for Codex. The other pages and every other proposal on the boards wait until they're decided.

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
| General | Reopening windows, the rail of organizations, the editor and terminal for Open in…, updates | The terminal for Open in Terminal, checking for updates and downloading them, and grouping and sorting the sidebar from the View menu |
| Appearance | Theme, text size, the house's animations, the code font and diff options, how lists are shown | The theme, the colors, the code font, the switch that turns the house off, and the file layout, branch sort and folded descriptions from menus |
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

- **The agents' pages, built for Claude Code and Codex.** The Commit page has only its Generate section. The Agents page has the agents Roga found, Look Again, each agent's hooks with Install… or Remove…, the switch for the sidebar's marks and a key to them. Each agent's page has its command's settings, the flags Roga always adds and why, Run a Test, and its hooks, but no model or effort of its own beyond the ones the Commit page and the Generate popover share. Left out: other agents, Add a Command, notifications, putting the worktrees that need you first, and answering permission requests in Roga. The help under the command block changed: the board's says the agent also reads the repository's CLAUDE.md or AGENTS.md, but `--safe-mode` leaves Claude Code's out, so the help says what's turned off instead. Built on November 6, 2026.

- **The General page, with only what works.** General comes first, beside Appearance, and Settings opens there the first time. It has two of the boards' three sections. **Open in** has Terminal, a popup of the terminals Roga finds on this Mac that open a new window in a folder they're handed: Terminal, iTerm, Ghostty and Warp. Open in Terminal uses the one chosen, or Terminal while that one is gone. Only Terminal could be tried here. **Updates** has Check for updates automatically and Download updates automatically, which are Sparkle's own settings, so its window's checkbox and these switches stay in step. Download is off and dimmed while checking is off, since Sparkle downloads only what its daily check finds. A copy of Roga built without Sparkle's key, as every build is until the first release, says so in a note above them and turns both off. The help under Check for updates says the sidebar shows a new version, rather than the board's "asks before it installs anything", which Download would make untrue. Left out: **Windows**, because reopening windows is new behavior nobody has asked for yet and the rail is kept by each window, which the View menu already handles; and **Editor**, because there's no Open in Editor yet. A switch that does nothing is worse than a short page. Sparkle no longer asks on the second launch whether to check, because `SUEnableAutomaticChecks` is on and General has the switch. Built on November 6, 2026.

- **A new version shows in the sidebar, not in Sparkle's window,** above the gear on the rail, or at the bottom of the list while the rail is hidden ([decision 43](../../decisions/0043-show-a-new-version-in-the-sidebar-rather-than-sparkles-window.md)). Decided on November 6, 2026.

- **No tiles for the agents, and their buttons beside their names.** The gray tile with two letters before each agent stood in for a logo Roga doesn't draw, and said nothing the name beside it didn't, so the Agents page has none. While Roga can't use an agent, because it didn't find it or it's turned off, the agent's name is gray instead. Install… or Remove…, and the switch and the chevron, sit on the name's line at the row's top right, as a row's commands do elsewhere in Roga, so they stay put when the words under the name wrap or an error appears under them. Every other row in Settings puts its control on its name's line too, so that one rule holds across the sheet: long help, like fetching's, keeps the switch by its name, and the hooks row on each agent's own page keeps Install… or Remove… beside "Hooks" when an error appears under it. The boards draw the rows this way too. Built on November 6, 2026.

- **The marks go on the right of a sidebar row, before the count of uncommitted files,** and stay while the pointer is over the row. The waiting mark is an amber `circle-alert` rather than the boards' triangle, because a red triangle already means conflicts ([decision 28](../../decisions/0028-show-a-worktree-thats-stuck-partway.md)). Decided on November 5, 2026.

- **The working ring turns,** clockwise, once a second, where the boards draw it still, because a quarter that never moves reads as progress stuck partway. The legends on the Agents page and each agent's page turn too, so that the key looks like the sidebar. Core Animation turns it, and it stops while its window can't be seen and for someone who asked for less motion ([decision 46](../../decisions/0046-turn-the-ring-of-an-agent-at-work.md)). Decided on November 6, 2026.

- **A theme of Roga's own.** Appearance starts with an Interface section and its Theme: System, which is the default, Light and Dark, with Lucide's `monitor`, `sun` and `moon`. Roga sets the application's appearance, so every window, sheet and menu changes at once, and it applies the stored theme as it starts, before its first window, so a dark theme never shows a light window first. Each choice has its word beside its icon, on the board too, because a monitor alone doesn't say "follow the system". The graph's lanes, the badges, the diff, the house (still or moving) and the menus all follow while they're on screen. A menu that's open while the theme changes keeps the look it opened with, as any macOS menu does, and the next one opens in the new theme. Built on November 6, 2026.

- **Settings is a row at the top of the sidebar,** under Add Repositories, now that organizations are groups in the list and the rail and its gear are gone ([decision 53](../../decisions/0053-organizations-as-groups-in-the-list-and-add-and-settings-at-the-top.md)). It keeps the darker gray while the sheet is open, as the gear did, and a new version shows as an orange row under it. Decided on November 7, 2026.

- **One switch for agents** ([decision 89](../../decisions/0089-one-switch-for-agents.md)). The Agents page starts with Use agents, and while it's on, has Agents, Claude Code, Codex and custom agents with Add Custom Agent… and Default agent, and Status, the hooks and the legend. Claude Code's and Codex's pages are their copy, model, effort and Run Test, and a custom agent's page is its name, command, Run Test and Delete Agent…. The Commit page folds into Git as Commit messages, and help that restated a title is gone. The boards here still draw the earlier pages. The Agent settings page of the canvas draws the new ones, from [`../agent-settings/boards.py`](../agent-settings/boards.py). Built on November 16, 2026.

- **Advanced folds into Git** ([decision 90](../../decisions/0090-fold-advanced-into-git.md)). Advanced had one setting, Keep commit-graph files up to date, so its Large repositories section moves to Git, after Fetching, and the sidebar ends at Agents. The boards here still draw Advanced, with the command log and reset it would have had. The Agent settings page of the canvas draws the Git page with Large repositories. Built on November 16, 2026.

- **The key to the marks is a piece of the sidebar,** the same one setup's Hooks screen shows, rather than a card of three rows with a worktree's name and what the mark means in a line. The sidebar's own rows draw it, and the rows around the three fade out with the sidebar's panel, so it reads as a glimpse of the window. Each mark has a line out to what it means. Changed on November 17, 2026.

- **Rows line up on their middle, and Git has fewer sections** ([decision 110](../../decisions/0110-line-up-settings-rows-on-their-middle-and-give-git-fewer-sections.md)). Each heading is as large as a row's name, with a line under it and 40 points before the next section, and a row's words and control line up on their middles, where the boards put each control on its name's line. Git has Installation, Identity, Signing and Background tasks, and the repositories that commit as someone else are on a page of their own, Repository overrides, which opens from Identity. Show Generate button is gone, so Use agents alone shows or hides Generate, and Commit messages moves to the Agents page, between Agents and Status. The boards here, and the agent settings and commit identity boards, still draw the old layout. Changed on November 25, 2026.

- **A switch that turns the house off ends Interface** ([decision 112](../../decisions/0112-let-the-house-be-turned-off-in-settings.md)). Animate the house comes after the code font, with "Shows the house in the title row and on the Fetch button while Git works." under it, and is on by default and stored as `animatesHouse` for every window. Turned off, the title row shows words after the counts while git pushes, pulls, undoes or aborts, and the Fetch button pulses rather than dropping the house. It isn't a Motion section of its own, which would hold one setting, and the card of the house's animations doesn't come back above it, because it would be a card of moving houses on the page where someone goes to stop them. Motion stays hidden with the speed slider. Built on November 26, 2026.

- **Fields and dropdowns are gray boxes with no line around them, as the Claude app draws its settings.** A text field, the paragraph box, a select and a popup share one 28-point box in the segments' gray, which lightens while the pointer is over it, and a one-point ring in the accent color, a point outside the box, while a field has focus or a dropdown's list is open. The search field at the top of the sidebar is drawn the same way, 30 points tall like the pages under it. A dropdown is the field with a chevron at its end, and a popup is as wide as its value, where it used to be words and a chevron with no box. Its list is Roga's own rather than the Mac's menu, so it can look like the Claude app's: a card at least as wide as the box, under it or over it when there's no room, with a gray rounded fill under the row the pointer or the keys are on and the check in the accent at the row's end. It opens on the press and takes the arrows, Return, Space, Escape and typed letters as a menu does, a press dragged onto a row and let go chooses it, and a long list scrolls. The two boxes of the code font's row have 8 points between them. Changed on November 26, 2026.

- **No tile before a program's name.** Git's row in Installation, and the program rows in setup, had a gray tile with Lucide's `git-branch` for Git and `square-terminal` for every agent, which said nothing the bold name beside it didn't, for the same reason the agents' tiles went. The row starts with the name, as the first-run boards describe it. The button at the row's end that opens the popover of copies, such as Homebrew, is a dropdown's box with its chevron, a step stronger than the card so it shows on it, and the same button on an agent's page, beside Model and Reasoning effort, is the page's own box. Changed on November 26, 2026.

- **What Roga found on the Mac is on a gray card; the settings about it are on the page.** Git's row sat on setup's gray card, while the agents and their plugins had a thin line around them, and nothing chose the difference: Git's row came from setup with its card, and the lists were drawn in Settings. So the agents' list and the Status list are on the same card as Git's row, with a line a shade darker than the card between rows, as setup draws Claude Code and Codex, and the outlined list is gone. A card holds the things Roga detected and reports on, one to a row, and the settings about them, such as Default agent, stay on the page. A button that isn't the main one, such as Remove…, and a custom agent's Custom tag are a step stronger than the card, as the Homebrew box is, and the rows start 16 points in, as Git's does. Changed on November 26, 2026.

## Still to decide

- **Which proposals to keep.** Open in Editor, reopening windows at launch, text size and date formats would each need work outside Settings first. Grouping and sorting the sidebar are app-wide already, so they could move here as they are.
- **Answering permission requests in Roga.** GitKraken offers it. It makes a hook wait for Roga, so the boards draw it off, and Roga leaves it out for now.
- **More agents.** Cursor Agent, Gemini CLI, Copilot CLI and a custom command are on the boards. Each needs its own way to install hooks and to run without tools.
- **Whether the boards should catch up.** They still draw the triangle, the still ring, the shorter commands and the old help under the command block, and General's Windows section, its Editor row and its help for updates.
