# 110. Line up Settings' rows on their middle, and give Git fewer sections

Accepted on 2026-11-25. This changes how every Settings page draws its sections and rows, where the [Settings design notes](../design/settings/README.md) put each control on its name's line. It also regroups the Git page that [decision 90](0090-fold-advanced-into-git.md), [decision 103](0103-show-who-commits-go-out-as-from-git-config.md) and [decision 109](0109-keep-the-signature-line-in-place-and-let-checking-be-turned-off.md) laid out. It removes Show Generate button, and it moves Commit messages from the Git page, where [decision 89](0089-one-switch-for-agents.md) put it, to the Agents page.

## Context

Settings' sections followed one another 30 points apart. Each had a heading at 15 points, as large as the page's title, and sometimes gray words under it, with a thin line only between rows. A row's control sat on the middle of its name's line, so a row with two lines of help had its switch level with the name and the help hanging below it. Other Mac apps' settings, such as ChatGPT's, leave more space between sections, put a line under each heading, and set the control on the middle of the row.

The Git page had seven sections for thirteen settings, and four of them held a single setting: Installation, Signed commits, Fetching and Large repositories. Identity had Name, Email, Sign commits, Format and Key. Under it, Repositories that commit as someone else listed every repository with an override, at full length, in the middle of the page.

The Git page's last section, Commit messages, had Show Generate button, Match repository commit style and Custom instructions. Show Generate button hid only the button in the message box. Generate Message (⌥⌘L) and Generate With still wrote messages, with the same instructions, so turning the button off didn't make the instructions irrelevant, though the page suggested it did. And what Generate sends the default agent was set on the Git page, while the agent itself was chosen on the Agents page.

## Decision

**Sections are 40 points apart, and each heading has a thin line under it.** A heading is 13 points and semibold, as large as a row's name, so that the page's title stays the largest words on the page. The line goes under the gray words when there are some. Then a line runs between each row, and none after the last.

**A row's words and its control line up on their middles,** with 12 points above and below them. A control with more under it marks its own middle. The Key field's line about the key, and New SSH Key…, hang under the field, and the row's name lines up with the field. The rows in the Agents page's lists, the agents and the hooks, line up the same way.

**Git has four sections:**

- **Installation**, as before.
- **Identity**: Name, Email, and Repository overrides.
- **Signing**: Sign commits, Format and Key, then Check signatures when a commit is selected.
- **Background tasks**: Fetch when Roga becomes active, and Keep commit-graph files up to date.

**Repository overrides is a row that opens a page of its own,** as an agent's row on the Agents page does. The row says how many repositories have an override, or None, with a warning before the number when one of them would fail to commit, then a chevron. The page has a back button in its title bar, which ⌘[ also presses. It lists the repositories as the section did, with Use Global and Set…, as plain rows between thin lines rather than inside a card. Settings remembers the page as it remembers an agent's page, under `settingsSubpage`, and choosing a page in the sidebar leaves it.

**Show Generate button goes.** The button shows whenever agents are on and an agent can run, as Generate Message and Generate With already did. Use agents is the one switch for Generate, as it is for Resolve, Fix and the sidebar's marks. The stored `generateShowsButton` is removed at launch.

**Commit messages moves to the Agents page,** between Agents and Status, with Match repository commit style and Custom instructions. They're what Generate sends the default agent, and like the rest of the page, they show only while agents are on.

**Search still finds each setting by its old section's name,** such as Large repositories, Fetching or "someone else".

## Consequences

- Pages are longer, with more room between sections and taller rows.
- The overrides take one row on the Git page however many there are, and seeing them takes a click.
- A row with long help no longer keeps its control beside its name, which the design notes gave as the reason for putting controls on the name's line.
- The Git page is only about git, and everything that Use agents turns on is on the Agents page.
- Someone who uses agents for the sidebar's marks but never generates a message sees the Generate button anyway, and someone who had turned it off sees it again.
- The Settings, agent settings and commit identity boards still draw the old layout and sections.
