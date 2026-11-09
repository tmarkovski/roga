# 65. Set Roga up in the whole window, the first time it runs

Accepted on 2026-11-09. This adds a first screen to the window of [decision 13](0013-repositories-in-a-sidebar.md), lets someone choose the git that [decision 3](0003-use-the-users-git.md) finds, and asks about the agents and hooks of [decision 41](0041-agents-status-from-their-hooks-and-messages-from-their-clis.md) before anyone has to find them in Settings.

## Context

Roga found git and the agents by itself and said nothing about it. That works until it doesn't. A Mac often has several gits, and Roga may run a different one than the terminal does. It has several copies of an agent too: Codex in Homebrew and another inside the ChatGPT app, or Claude Code once in `~/.local/bin` and again under each version of Node. Nothing showed which copy Roga ran or offered another, except a Choose… button on each agent's page that opened a file panel.

Hooks were worse off. The sidebar's marks, which are much of what Roga is for, only work once the hooks are installed, and the button for that was on a page of Settings that someone had to go looking for.

Three drafts were drawn on the design canvas. The first was a sheet over the empty window, which read as an interruption. The second took the whole window, but spread one decision over two switches and a line of text, opened a list of copies away from the row it belonged to, and had a button that didn't say what it installed. The third is what was built, and [docs/design/first-run](../design/first-run/README.md) has the boards and what was learned from each.

## Decision

**Setup takes the whole window, and the window becomes the app when it's done.** It shows the first time Roga runs, for someone with no repositories in the sidebar. Anyone who has some was using Roga before setup existed and never sees it. There's a screen to a step: Welcome, Looking, Git, Agents, Hooks and Ready. Each has one centered column with a heading, what Roga found, and its buttons. Dots at the top say how far along it is, and the house walks along a floor at the bottom, and waddles while Roga is busy.

**Roga looks first, and only stops where there's a choice or something's missing.** Looking shows the login shell's `PATH`, git and each agent as Roga finds them, and installs and changes nothing. Every later screen comes filled in with what Roga would do by itself, so the dark button is the quick way through.

**A program is a row, and its copies are a menu on that row.** Git, Claude Code and Codex each get the same row: the name, the version, a check for having been found, and the path. A button at the row's right names where that copy is from, as in Xcode or ChatGPT app, and opens a menu under itself of every copy Roga found, each with its version, its path, and why Roga would or wouldn't run it. The one Roga uses by itself is marked Recommended, and Choose Another… takes a copy from anywhere else. Settings uses the same row for git, and the same menu for each agent's program.

**A step someone can decline is answered with its buttons.** Agents asks "Use Claude Code and Codex in Roga?" and ends in Don't Use Agents and Use Agents. Hooks ends in Not Now and Install Hooks. Leaving one agent out is Don't Use Codex in that agent's menu, which turns off the switch the agent already has in Settings. Don't Use Agents turns that switch off for every agent, found or not, so that one installed later isn't used until someone turns it on.

**The Hooks screen says why, then what, then how.** A picture of three sidebar rows, each with a line out to what its mark means. Then a sentence that says what Install Hooks does. Then a card with each agent's status that ends in the exact commands, as [decision 29](0029-dialogs-that-say-what-happens-and-show-the-command.md) asks of anything Roga runs. After Install, the commands give way to what happened in each agent. Setup doesn't wait for Codex to trust the hooks, because that happens in another app: the row says it's waiting, with Check Again, and Ready marks the line in amber.

**Ready says what was chosen, and asks one more thing.** Each line has a mark and Change, which goes back to the step that set it. Under it are the two switches for updates, which no other step asks about.

**A git someone chose is saved, and takes over when Roga next opens.** Until now nothing could choose a git, although decision 3 allowed for it. The choice is saved, and Roga uses that git or says why it can't, and never passes it over for another. In setup it takes effect at once, because no repository is open yet. In Settings it takes over the next time Roga opens, and Settings says so, since every repository in the sidebar is opened with one git and keeps it.

**Roga lists the Command Line Tools' own git as well.** `/usr/bin/git` runs the git of whichever developer tools `xcode-select` points to, so with Xcode chosen, the git in `/Library/Developer/CommandLineTools` is another one that people have without knowing. The menu lists it last. Launch still looks only where it did, and falls back to that git when it finds no other it can use.

**Setup needs a usable git and nothing else.** With none, the Git screen says which gits it found and why it can't use them, and offers to install the Command Line Tools with `xcode-select --install`, which it shows. Roga looks again when someone comes back to it. With no agent found, Agents says so and goes on.

## Consequences

- Roga asks each git and each copy of an agent for its version at launch, where it used to stop at the first git it could use. They run at once, and the git that every window waits for is still found first.
- Choosing a copy from a menu shows at once, because Roga already knows its version. Only a copy from Choose Another… has to be asked.
- There's no single switch for not using agents. Don't Use Agents sets each agent's own, which keeps one way of saying it, and means Settings › Agents shows two switches that are off after it.
- Changing git in Settings doesn't reach the repositories that are already open. Reopening every session with another git would stop whatever they were doing, for a setting that rarely changes.
- Someone who quits partway through sees setup again from the start, with what they chose so far already in place.
- Setup shows again after `defaults write sh.roga.app setupDone -bool false`, or when Roga is started with `-setupDone NO`.
- Signing in to GitHub isn't part of it. The boards hold a place for it, and Roga isn't a hosting client.
