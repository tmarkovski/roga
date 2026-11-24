# 101. Choose a program's copy in a popover like the agents'

Accepted on 2026-11-24. This changes how [decision 69](0069-set-roga-up-in-the-whole-window-the-first-time-it-runs.md)'s rows for git, Claude Code and Codex list their copies, from a menu under the row's button to the popover of cards that [decision 91](0091-one-agent-popover-for-every-agent-button.md) gave the agents. It drops decision 91's exception that setup's menus of programs keep their check.

## Context

Roga chose a tool two ways. The chevron beside Generate, Resolve and Fix opens a popover titled Default agent, with a card for each agent, a radio on each card and an ink edge on the one picked (decision 91). The button at the right of a program's row, on setup's Git and Agents screens and on Settings' Git and agent pages, opened a menu that Roga drew itself over the window, with a check before the copy in use and three lines for each copy: where it's from with its tag and version, its path, and why Roga would or wouldn't run it. Decision 91 kept that menu, on the grounds that a menu marks a choice with a check.

Going through setup on 2026-11-24, the menu read as a different control from the agents' popover, though both choose which program Roga runs, and two of the screens that choose one sit right before Hooks, which installs into the same agents. Setup is also the first place anyone chooses a tool in Roga, so it should look the way choosing a tool looks everywhere after it.

## Decision

**A program's row opens a popover of its copies, laid out as the agents' is.** The button at the right of the row still names where the copy in use is from, as in Homebrew or ChatGPT app, and still has its chevrons. Clicking it opens a popover under the button, titled for the program, as in Git installation or Claude Code installation. Each copy Roga found is a card with a radio, where it's from with its tag and its version, its path in the code font, and why Roga would or wouldn't run it. The copy in use has the ink edge twice as thick as the others' line, and the pointer over another card that can be picked shades it, as on an agent's card. A copy Roga can't run stays in the list, in the order Roga looks, gray with its radio faded, and keeps its tag and its reason readable, as decision 69 says of the menu.

**A pick is used at once, and the popover stays open to show it.** Clicking a card makes that copy the one Roga runs, as choosing from the menu did, and the edge moves to it. A line under the cards says "Selection saved automatically.", as the agents' popover does, and Choose Another… beside it closes the popover and opens the panel that takes a program from anywhere else. Escape, a click outside and the button itself close it.

**Setup and Settings use the same popover**, as they used the same menu: Git on setup's Git screen and Settings' Git page, and Claude Code and Codex on setup's Agents screen and their pages in Settings.

## Consequences

- The menu Roga drew over the window goes, with what it took to draw it over everything else and keep it on screen, and its own arrow keys and Return. The popover is a panel, so Tab moves through its cards and Space picks one when keyboard navigation is on, as in the agents' popover.
- The popover is a window of its own, so it can reach past setup's column and past the sheet Settings is in.
- There's still no way to leave one agent out from its popover, since agents are on or off together ([decision 89](0089-one-switch-for-agents.md)).
- The Recommended tag still goes to the copy Roga uses by itself, which for git is the first one it can use in the `PATH`, the one the terminal runs ([decision 3](0003-use-the-users-git.md)). So a Homebrew git can be recommended over a newer one from Xcode.
- The First run boards on the design canvas still draw the menu.
