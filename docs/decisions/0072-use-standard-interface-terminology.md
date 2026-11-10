# 72. Use standard interface terminology

Accepted on 2026-11-10. This revises interface wording from [decision 41](0041-agents-status-from-their-hooks-and-messages-from-their-clis.md) and [decision 69](0069-set-roga-up-in-the-whole-window-the-first-time-it-runs.md).

## Context

Headings such as “How Roga runs it,” “What you chose” and “One more thing” make the interface read like a conversation. They also make settings harder to scan because they describe the application's narration instead of naming the setting or feature. The same pattern appears in output labels, agent status descriptions and conflict controls.

## Decision

Use familiar software and Git terminology for labels. Headings name the subject, buttons name the action, and supporting text states the behavior or consequence directly.

| Previous wording | Revised wording |
| --- | --- |
| How Roga runs it | Command-line arguments |
| Program, on an agent's settings page | Executable |
| Extra arguments | Additional arguments |
| Time limit | Timeout |
| Reset to Roga's | Restore Defaults |
| What Claude Code printed | Claude Code output |
| What you chose | Configuration |
| One more thing | Updates |
| What both started from | Common ancestor |
| Put Conflicts Back | Restore Conflicts |

Descriptions should be concise and factual. State which inputs are sent to an agent, which arguments are applied, and what permissions or side effects apply. Avoid conversational filler such as “a small job small,” vague pronouns, and descriptions of what Roga “says” or “thinks.” Use “approval” for permission requests and “response” for questions.

Keep the capitalization rules in [decision 66](0066-sentence-case-branch-icons-and-the-value-on-a-row.md). This is a wording change, not a change to how settings or commands work.

## Consequences

Settings, setup, agent controls and conflict resolution use the same terms. Existing copy assertions are updated alongside the visible text. Earlier design boards remain historical references for layout; this decision governs their interface wording.
