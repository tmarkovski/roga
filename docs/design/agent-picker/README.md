# Agent picker

Boards for how Generate's popover marks the default agent, where each agent's model and effort are changed, and how Resolve and Fix choose their agent where they run. They're on the Agent picker page of the design canvas [yaga layout options](https://claude.ai/artifact/4WQVua6gwKqSBoiRdf2FhX), and [`boards.py`](boards.py) draws every board.

They build on [decision 89](../../decisions/0089-one-switch-for-agents.md), from the `tm/agents-by-job` branch, where Generate, Resolve and Fix all run one default agent and custom agents sit beside Claude Code and Codex.

The page has today's popover, Resolve and Fix, then three options for the popover:

- **A** brings back the radio for the default agent and puts a ⋯ at the right of every row. Its menu has the agent's models and efforts with checks, then the agent's page in Settings. One frame swaps the ⋯ for a gear to compare.
- **B** draws each agent as a card, with the default's edge in ink, and the same ⋯ as A.
- **C** adds no buttons and makes each row's gray second line the button that opens the same menu.

After that, Resolve in the diff's header and Fix in a refusal become split buttons like Generate's. The main part runs the default agent, and the chevron opens the same popover as Generate's, hanging under the button, with that job's own command along its bottom. A pick changes the one default, so every button names the new agent. Try it is clickable, and every chevron on it opens that popover.

## Decided

- **B, and one popover for every chevron.** Generate, Resolve, Fix, and Try Again after a fix that failed all open the same popover: B's cards with the radio, each agent's ⋯ for its model and effort, a line naming what else uses the default, and the command that job runs. A native menu under Resolve and Fix was drawn first and dropped, so that choosing an agent looks and works the same everywhere. Decided on November 17, 2026, and built as [decision 91](../../decisions/0091-one-agent-popover-for-every-agent-button.md), whose code is what counts now.

## Still to decide

- **A stronger model for a harder job.** Model and effort stay with the agent, so raising Claude Code to sonnet for a hard conflict also slows commit messages. A job could ask for a stronger model than the default's, but that's a setting for each job again, which decision 89 turned down, so it waits until someone needs it.

## Regenerating the boards

Read `project/canvas.json` from the canvas into a folder first, so that the merge starts from what's live, then:

```bash
uv run docs/design/agent-picker/boards.py --out <folder> --canvas <folder>/project/canvas.json
```

It writes the `Ap-*.dc.html` boards into `<folder>/project/` and replaces the Agent picker page's boards and notes in that `canvas.json`, leaving every other page alone. Publish those files to the canvas.
