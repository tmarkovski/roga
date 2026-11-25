# 89. One switch for agents, a default agent, and custom agents

Accepted on 2026-11-16. This changes where [decision 41](0041-agents-status-from-their-hooks-and-messages-from-their-clis.md) put the agents' settings: the Agents page, each agent's page, and the Commit page, which folds into Git. It replaces each agent's Enable switch and the sidebar's switch with one switch for agents, and Generate's agent with a default agent, which also resolves conflicts ([decision 60](0060-resolve-conflicts-in-the-diff-panel.md)) and fixes what git refused ([decision 63](0063-ask-an-agent-to-fix-what-git-refused.md)). It adds agents that are a command someone types. It changes what the Agents screen of [decision 69](0069-set-roga-up-in-the-whole-window-the-first-time-it-runs.md) stores. Amended in place on 2026-11-25: Add Custom Agent… moved from the list's last row to under the list at its right edge, in the accent, as New SSH Key… sits under the Key field ([decision 108](0108-make-a-signing-key-and-say-which-signing-programs-are-here.md)).

## Context

Settings set most things about agents in three places, and some of them read as if they did something else:

- The Agents page listed Claude Code and Codex twice: once with an **Enable** switch and a chevron, and again with the hooks' **Install…** or **Remove…**. Each agent's page repeated both, with a table of hook events.
- **Enable** only decided whether Roga ran the agent for Generate, Resolve and Fix. Hooks and marks ignored it, and its help had to say "Hook settings are independent." The sidebar's marks had a switch of their own.
- Which agent ran was chosen on the Commit page under "Commit message generation", in the Generate popover and from Generate With. That agent also resolved conflicts and fixed git errors, and nothing on screen said so.
- Model and effort were set on the Commit page, on the agent's page and in the popover. The agent's page also had extra arguments, a time limit, a card of flags and the command, most of it about commit messages, which the Commit page was about too.
- Much of the gray help under a setting said again what its title said.

A first version of this decision split the settings by job, status and actions, with a choice of agent for actions that could be None. Looked at on the canvas, that kept a setting for each thing agents do, which is the confusion it set out to remove. The person deciding wanted agents on or off as one thing, then a default, then agents of their own.

The Agent settings page of the design canvas draws today's pages beside these, and its generator is [`docs/design/agent-settings/boards.py`](../design/agent-settings/boards.py).

## Decision

**Use agents turns everything about agents on or off.** It's the first row of the Agents page, with one line of help that says what agents bring. While it's off, nothing else shows on the page, Git's Commit messages section is hidden, and search finds only the switch. Roga doesn't look for agents, Generate, Resolve and Fix are hidden, the sidebar shows no marks, and nothing listens for the hooks' socket. Hooks already installed stay, and return at once with nobody listening. It replaces each agent's Enable and **Show agents in the sidebar**. It's stored as `useAgents`, on while it's absent.

**While it's on, the Agents page has two sections.**

- **Agents** lists Claude Code and Codex, whether or not Roga found them, then the custom agents, each with its program or command under its name and the chevron to its page, and **Add Custom Agent…** under the list at its right edge, in the accent. **Rescan** sits at its top right. Its one line of help says that Generate, Resolve and Fix run the default agent with its tools off, and send what they need to its provider. **Default agent** comes after the list, a choice of every agent Roga can run, custom ones too, with no None: turning agents off is Use agents.
- **Status** has the hooks for Claude Code and Codex, the only agents whose hooks Roga can install, and the legend of the sidebar's marks. A custom agent isn't in it.

**The default agent is one stored value, `defaultAgent`**: `claude`, `codex` or `custom.` and a custom agent's ID. While it's absent, or names an agent Roga can't run now, Generate, Resolve and Fix run the first agent Roga can, Claude Code before Codex before custom agents. What was chosen stays stored, so a Codex that's back is the default again. Picking an agent in the Generate popover or from Generate With stores it, as before.

**A custom agent is a name and a command**, such as `ollama run qwen2.5-coder:7b`. Roga runs the command with `/bin/sh -c` in the worktree, with git's environment and `PATH`, and puts its instructions, the task and the data on standard input, since it knows none of the command's flags. What it prints is the answer, and an exit status other than 0 is a failure, said in the first line it printed. It has no hooks, no model or effort, and nothing to find. **Add Custom Agent…** is a Roga dialog with the two fields, Run Test, and the command along its bottom edge. A custom agent's page has its name, its command, Run Test and **Delete Agent…**, which asks first and says what runs instead when it's the default. Custom agents are stored as JSON under `customAgents`.

**Claude Code's and Codex's pages are which copy, the model, the effort and Run Test.** Extra arguments, the time limit, the card of flags and the command are gone, and so are the hooks. The exact command still shows in the Generate popover and in Resolve's tooltip, as decision 29 asks. The time limit is fixed: 60 seconds for a message, and at least 3 minutes to resolve or fix. Under the Executable row, a copy that's found shows its path and version and no sentence, since the menu says where it's from.

**The Commit page folds into Git**, as **Commit messages**: Show Generate button, Match repository commit style and Custom instructions. The Agent row and the command are gone, since the agent is chosen on the Agents page. Settings' sidebar has General and Appearance, Git, Agents, and Advanced.

**Gray help stays only where it says something the title doesn't**: a side effect, what's sent somewhere, or a requirement that isn't plain. Help under Terminal, Code font, File layout, Branch sorting, Fold commit descriptions, Show Generate button and Default agent is gone, and so is the Open in section's. Download updates, Fetch, Match repository commit style, the commit-graph setting and Git's requirement are shorter. Search still finds each by the words it lost.

**What Settings kept before moves over once.** At launch, both agents' Enable off becomes Use agents off. Generate's agent becomes the default while it was on, and with only one switched on, that one is. A default stored since wins. Then the old keys go, with `agentsShowInSidebar`, and each agent's `extraArguments` and `timeLimit`.

**Setup asks one question, as before.** Agents asks "Use Claude Code and Codex in Roga?" and **Don't Use Agents** or **Configure Hooks** answers it, which stores Use agents. The rows keep their menus of copies, without **Don't use Codex**, since agents are on or off together. A line under them names the default, "Claude Code is the default. You can change this later in Settings › Agents." Hooks follows Configure Hooks, as before, and Ready says which agents are in use and which is the default. When setup shows with agents turned off, Roga looks for them anyway, so the screen can ask.

## Consequences

- There's no way to keep one found agent from being used while the other is. Someone who wants only Codex makes it the default, and Claude Code shows in the Generate popover and Generate With without running unless picked.
- Someone who turned the sidebar's marks off while keeping Generate gets the marks back. Marks follow the hooks, which they can remove.
- Resolve and Fix still run at the default agent's model and effort, which is Haiku at low effort for Claude Code by default. The Agents section now says the default runs all three.
- A custom agent's command is someone's own, so Roga can't turn off its tools or say what it sends where. The Fix dialog leaves out "Agent tools are disabled" for one.
- The engine's agent is now Claude Code or Codex at a path, or a custom command, and its errors name the agent by its name rather than its kind.
- Status for other agents, such as GitHub Copilot's command-line tool, would join Claude Code and Codex in Status once Roga can install their hooks. That's its own change.
