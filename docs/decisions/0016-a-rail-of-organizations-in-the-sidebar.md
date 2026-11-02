# 16. Pick repositories by organization with a rail in the sidebar

Accepted on 2026-11-02. This changes the order that [decision 14](0014-the-sidebar-keeps-every-added-repository.md) gave the sidebar, and settles how repositories are reordered and what Command-1 to Command-9 do, which the [main window](../main-window.md) left open.

## Context

The sidebar lists every repository the user has added, with each repository's name, its folder and its worktrees. That works for a few repositories, but each repository and each worktree takes a 54-point row, so about 13 rows fit in a window 860 points tall. Someone who works across several organizations, with agents in many worktrees, can have 30 repositories and 60 worktrees. They need to see what's going on without scrolling through all of it.

We drew the options on a design canvas: flat lists, dots for what's going on, folding what's quiet, grouping by organization, and a view of only the work in progress. The options answer two separate questions, which repositories to look at and how to arrange them, so they combine rather than compete. The user works across three or more organizations every day, so switching between them has to be one click, as in Slack.

## Decision

**A rail picks which repositories the sidebar lists.**

- The rail is a 56-point column at the left of the sidebar. From the top, it has All, then each organization from A to Z, then Other. A button at the bottom adds repositories.
- An organization is the owner in a repository's `origin` URL, which is the first segment of the URL's path. yaga reads it from the repository's configuration, so it needs no network or account. An owner with one listed repository goes in Other, with the repositories that have no `origin`, so that a stray clone doesn't get a place on the rail.
- Organizations show two letters from their name. yaga doesn't load avatars, because that would be its only reason to use the network.
- Clicking an organization brings back the worktree last shown there, the way Slack brings back a channel. The first time, it's the first repository's main worktree. Clicking All keeps the window on what it shows.
- Each window remembers its own organization and the last worktree in each, along with its selected worktree (decision 14).
- Command-1 selects All, and Command-2 to Command-9 select the items after it. The View menu lists them and can hide the rail, which leaves All.

**A repository's row is its main worktree.**

- Clicking the row selects the main worktree, and the triangle after the name shows or hides the linked worktrees. A repository with no linked worktrees has no triangle.
- Rows are one line, 32 points tall. A row no longer shows the repository's folder, except when two listed repositories have the same name, and a worktree's folder moves to its tooltip. A repository whose main worktree has a branch other than `main` or `master` shows the branch in gray.
- A repository starts collapsed. The selected worktree always shows, even under a collapsed repository or organization.

**What's quiet folds.**

- A worktree is quiet when it has no uncommitted files and isn't selected. When a repository is expanded, two or more quiet worktrees fold into one row, such as **3 quiet worktrees**, which unfolds them.
- A repository is quiet when none of its worktrees has uncommitted files, none is selected, and the user hasn't expanded it. When All is selected, repositories are grouped under their organizations, and two or more quiet ones fold in the same way.
- An organization's header in All collapses the whole group. Other starts collapsed.
- Repositories go from A to Z, by name. They can't be reordered by hand, so a repository stays where the eye expects it as the list grows. Other lists owners' repositories as `owner/name`, under **Other owners**, and then the ones under **No remote**.

**Adding repositories from this Mac.**

- The button on the rail lists the clones in the folders the user has already added repositories from, one level deep, leaving out what's listed. With an organization selected, it lists that organization's clones. The user checks the ones to add.
- It can look in another folder too. It finds a clone by its `.git` folder, and asks git for the `origin` URL.
- Opening a repository from the File menu still works as before, for one in any other place.

**What waits.**

- A view of only the work in progress, with **To review** and **Working** sections and a switch to it, waits until yaga knows what agents are doing. That will come from the agents' hooks, rather than from guessing based on when files stop changing. The rail and the rows have room for its marks and counts.
- Listing an organization's repositories on GitHub with the `gh` command needs its own decision, as the [roadmap](../../ROADMAP.md) says for any integration with a host, and cloning is release 2.

## Consequences

- At 32 points per row, about 25 rows fit in the same window, and many repositories take only one.
- The sidebar is 312 points wide by default rather than 250, which leaves less for the middle of the window. The refs panel gives way a little sooner in a narrow window.
- The list in `repositories.json` keeps the order repositories were added in, and only the sidebar sorts it. Each entry also saves the repository's owner, so that the rail is in its usual order at launch and a repository on a disk that isn't mounted stays in its organization.
- yaga runs one more short git command per repository each time it refreshes the list, to see whether `origin` changed.
- Adding repositories can run many short git commands at once in a folder with many clones, so it runs a few at a time.
- A worktree where an agent has committed everything looks quiet and folds. Until yaga knows about agents, the fold row is the way to get to it, or the refs panel, which lists every branch and the worktree it's in.
- An owner's name is the first path segment on every host, which on GitLab means a group's top level rather than its subgroup.
