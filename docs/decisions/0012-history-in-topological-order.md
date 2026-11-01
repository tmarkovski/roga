# 12. Show history in topological order by default

Accepted on 2026-11-01.

## Context

git can order history in two ways that both keep every parent below all of its children. Date order, `git log --date-order`, shows commits newest first by commit time, so commits from branches that grew at the same time are interleaved. Topological order, `git log --topo-order`, follows one line of history until it reaches a commit that's still waiting for other children, so each branch's commits stay together. `git log --graph` uses topological order. Many graphical Git clients use date order.

The commit-graph reader does both. On Linux, both have the first screen ready in about 5 ms and order the rest in about half a second, and both match git's order for every commit.

Release 1 is for someone who works in the terminal and keeps yaga open next to it, often to review what several agents did on their own branches at the same time.

## Decision

The commit list shows history in topological order by default. A switch in the history panel's header changes it to date order.

## Consequences

- The graph looks like the one `git log --graph` draws, which yaga's users already read.
- Commits from parallel branches, such as each agent's worktree branch, appear as one block per branch rather than interleaved, which makes it easier to review one branch at a time.
- We expect fewer lanes and fewer crossing lines than in date order, because a branch's lane doesn't stay open across the rows of every other branch. The prototype's date-order layout of Linux was up to 702 lanes wide. The lane layout should measure both orders on Linux to confirm this.
- Recent work on one branch can appear below the whole of another branch when that branch is long, such as a release branch that diverged months ago. Date order shows such history as a timeline, and the switch keeps it a click away.
