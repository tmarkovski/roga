# 91. One agent popover for every agent's button

Accepted on 2026-11-17. This changes the popover that Generate's chevron opens ([decision 41](0041-agents-status-from-their-hooks-and-messages-from-their-clis.md)), and gives Resolve ([decision 60](0060-resolve-conflicts-in-the-diff-panel.md)) and Fix ([decision 63](0063-ask-an-agent-to-fix-what-git-refused.md)) the same chevron. It builds on the one default agent of [decision 89](0089-one-switch-for-agents.md).

## Context

Generate's popover marked the agent it runs with a small check before its name, the way a menu marks a choice. It had a radio at first, and the check replaced it so that the popover matched setup's menus. Only the picked agent's model and effort were menus, drawn as two boxed words on its second line, while the other rows said theirs in gray. Picking a row moved the menus to it, so the words under an agent's name turned into controls depending on which row was picked, and changing another agent's model meant making it the default first.

Since decision 89, Generate, Resolve and Fix all run one default agent. Resolve with Claude and Fix with Claude said which agent they would run but couldn't change it, so trying another agent on a conflict, or on a refusal that the first agent couldn't explain, meant going to Generate's popover or to Settings first. The refusal's dialog also kept the agent it opened with, because a sheet doesn't redraw what it shows while its dialog stays the same.

The Agent picker page of the design canvas draws today's popover beside three options, and its generator is [`docs/design/agent-picker/boards.py`](../design/agent-picker/boards.py). A brought back the radio and put a ⋯ on every row, B drew each agent as a card, and C made each row's gray second line the button. B was chosen. The page also drew a native menu under Resolve's and Fix's chevrons, which was dropped so that choosing an agent looks and works the same everywhere.

## Decision

**One popover opens from every agent's chevron.** Generate's chevron opens it over the message box, as before. Resolve in the diff's header and Fix in a refusal's dialog become split buttons like Generate's, and their chevrons open it under the button. So do Fix with Claude after git refuses what the agent suggested, and a new Try Again when the agent couldn't answer. The main part of each button runs the default agent, and the button names it.

**It's titled Default agent, and each agent is a card.** A card has a radio, the agent's name, and its model and effort on a second line, as in `haiku · low effort`, or a custom agent's command, or why the agent can't be used. The default agent's card has an ink edge twice as thick as the others' line. Clicking a card makes that agent the default. The popover is a panel rather than a menu, so it marks the choice with a radio, as the Mac's panels do. Setup's menus of programs keep their check, as menus do.

**A ⋯ on each card has the agent's model and effort.** It sits at the right of the name's line, as Roga's rows put their controls, and opens one of Roga's own menus, as the sidebar's Group and Sort button does. Model and Effort are its rows, each a submenu of the choices with a check on the chosen one, and each row names what's chosen, dimly before its arrow, as Sort by does. Then comes the agent's page in Settings. Codex's models end with Another model…, which opens its page to type one. A custom agent's ⋯ has only its page, and so does the ⋯ of an agent that can't be used. Changing a model there doesn't pick the agent, so another agent's model can change without making it the default. It's a ⋯ rather than a gear because Roga uses ⋯ for a row's menu, in the sidebar, the refs panel and a conflicted file's header, while a gear has meant Settings. The menu stays at model, effort and the agent's page: Roga runs these agents with their tools, plugins, hooks and MCP servers turned off, and decision 89 already fixed the timeout and removed additional arguments.

**The command along the bottom is the one that job runs.** Generate's, Resolve's and Fix's commands have the same flags, each with its own prompt and its own data on standard input, so the first line of the block says what goes there: the staged diff, the conflicts, or Git output and diagnostics. The line under the cards says the pick is saved, and names the other two jobs that use the same agent, as in "Selection saved automatically. Generate and Fix use the same agent." The popover keeps room for the longest of the agents' commands for that job, so it's the same height whichever agent is picked.

**A pick changes the one default.** Every button that runs an agent names the default, so picking Codex under Resolve renames Resolve, Generate and Fix at once. Each job doesn't keep an agent of its own, which decision 89 considered and turned down.

**A dialog follows the pick while it's open.** The refusal's dialog and the steps of asking an agent read the default agent as they draw, so Fix names the agent picked from its chevron and asks that one. Asking again after git refused a suggestion can ask another agent, which is still told what was tried and what git said about it. When the agent couldn't answer, Try Again asks the same question again, of the agent that's picked. Settings is a sheet on the window, which can't open over a dialog's sheet, so inside a dialog the ⋯ menus leave out the agents' pages and Another Model…, and a custom agent's card has no ⋯.

## Consequences

- Model and effort still belong to the agent, not the job. Raising Claude Code to sonnet for a hard conflict also slows commit messages until it's set back, as decision 89 says. A job asking for a stronger model than the default's would be a setting for each job again, so it waits until someone needs it.
- The popover is a little taller than before, since the cards have room between them.
- A conflicted file's ⋯ menu still has Resolve with the default agent, which follows the pick, and the strip above a file whose agent failed still has Try Again with the same agent. The header's chevron is right above it.
- An answer with no commands still offers only OK. It could get Try Again with the chevron too, as the failure step has.
- The Settings boards and the first Agent settings boards still draw the old popover, with a check or a radio and chips. The Agent picker page draws this one.
