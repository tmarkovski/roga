# 90. Fold Advanced into Git

Accepted on 2026-11-16. This changes Settings' sidebar, which ended with an Advanced page, and the Git page. Partly superseded by [decision 110](0110-line-up-settings-rows-on-their-middle-and-give-git-fewer-sections.md), which puts Keep commit-graph files up to date beside Fetch when Roga becomes active, in a section called Background tasks, and moves Commit messages to the Agents page. The rest of this decision still holds.

## Context

Settings' sidebar had General and Appearance, then Git, Agents and Advanced, with a line between each group. Advanced had one section, Large repositories, with one setting, Keep commit-graph files up to date ([decision 6](0006-keep-the-commit-graph-up-to-date.md)). The Settings boards also proposed a command log and a way to reset every setting there, and neither was built. A page for one switch takes a place in the sidebar and a click, and "Advanced" doesn't say what's on it, so nobody looking for the switch has a reason to look there.

[Decision 89](0089-one-switch-for-agents.md) had just folded the Commit page into Git as Commit messages.

## Decision

**Advanced goes, and Large repositories moves to Git**, after Fetching and before Commit messages, with its switch and help as they were. It goes on Git rather than General because it's about what Roga does with git in each repository: it runs `git commit-graph write` and writes to the repository's objects folder. General has what's about Roga itself, Open in and Updates.

## Consequences

- The sidebar has General and Appearance, then Git, then Agents.
- Git has Installation, Fetching, Large repositories and, while agents are on, Commit messages.
- Settings left on Advanced opens on General the next time, as it does when it was left on the Commit page.
- Search finds the switch by the same words, and names Git as its page.
- A command log or a reset, if they come, need a home other than Advanced.
