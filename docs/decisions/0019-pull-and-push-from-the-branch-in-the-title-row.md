# 19. Pull and push from the branch in the title row

Accepted on 2026-11-03. Pulling, pushing and creating branches come in release 2, so none of this is built yet.

## Context

Release 2 adds the actions people reach for most in a Git client: pull, push and creating a branch. They act on where the user is, which is the branch the worktree has checked out, rather than on the commit selected in history, and the design has to make that plain. We also wanted them to carry some of yaga's identity, rather than looking like any other client's toolbar.

We drew the options on a design canvas, all with the same data and with a commit below `HEAD` selected:

- **Icons right after the branch.** They read as acting on it, but they move by about 150 points when switching worktrees changes the length of the branch's name, so they can't be clicked from memory.
- **Icons in the middle of the row.** Nothing else lives there, they move when the sidebar or the refs panel is resized, and at the narrowest middle column, 400 points, they leave no room for the branch.
- **Icons at the right, beside history's commands.** They stay put, and it's where a Mac toolbar keeps commands, but they read as more of history's commands and don't say what they act on.
- **The same with labels, in a box.** This is loud enough, but it takes about 210 points of a short row and looks like every other Git client.
- **One button for the next step**, as GitHub Desktop has. What it does changes, so it can't be clicked from memory.
- **A row for where you are, at the top of history.** It takes a row of height all the time, including for a clean worktree, which has no row today ([decision 15](0015-uncommitted-changes-as-a-row-in-history.md)), and it puts buttons in a row that can itself be selected.
- **A capsule floating over history.** It's the loudest, but it covers rows, and nothing else in yaga floats.
- **On the sidebar's rows.** This would let someone push without selecting the worktree, but it's hidden until hover and the sidebar can be closed, so it could only go with another option.

## Decision

**The title is the control.** The row reads `agents-demo`, then the branch as a chip with a branch icon and a small triangle, then `↓3` and `↑1`, then `· 128 commits`. The chip opens a menu, and the counts are the buttons for pulling and pushing. A count shows only when there's something to pull or push. The row reads as a sentence, and it tells someone watching agents where a branch stands rather than only offering a command.

**Everything acts on the worktree's branch, whatever is selected.** Hovering a count tints the commits in history that it would move. Its tooltip names the branch, the remote and the git command, as in **Pull 3 commits from origin/main into main** and `git pull --ff-only`. A right click on a commit can offer New Branch Here for when someone does want the selected commit.

**Orange means a click runs now.** `↓` is orange whenever the branch is behind. `↑` is orange when the branch is ahead and not behind. When it's both, `↑` stays gray, because git would reject the push, and clicking it opens the menu. A branch that has never been pushed shows a gray `↑ Push`, because agent branches live like that and the orange would never go away.

**Pull follows the user's git config.** A branch that's only behind runs `git pull --ff-only`. A branch that's also ahead runs what `pull.rebase` says. Only when that isn't set does clicking `↓` open the menu, which offers **Rebase main onto origin/main** and **Merge origin/main into main**.

**The menu has the rest.** It starts with the upstream, how far the branch is from it and when yaga last fetched. Then come Pull, Push, Fetch, New Branch and Switch Branch, which opens the refs panel's filter. Holding Option swaps Push for Force Push with Lease, which says what it will overwrite before it runs, as the vision asks of destructive operations.

**New Branch can start a worktree.** It opens a popover under the chip with a field for the name and a checkbox for **In a new worktree**, because that's how someone starts an agent. The popover shows the exact command as it's typed, `git switch -c fix-retry` or `git worktree add -b fix-retry ../fix-retry`.

**While git runs, the house walks.** The house from the mark waddles in place of the counts, beside **Pulling…**, and nothing else runs until it finishes. Then **✓ Pulled 3** shows for 3 seconds. When git refuses, an alert shows what git said and nothing changes, as with a failed checkout, so no failure stays behind in the row.

**The icons are drawn from the commit graph.** A solid node is the branch you're on, and an arrow says which way commits go: Pull's arrow lands on the node and Push's leaves it. Fetch's node is hollow, because a fetch leaves the branch alone, and Branch is a node with a line that forks to a hollow one. We compared them with plain arrows, which say nothing about yaga, arrows on a line, which is what most Git clients draw, and a family built on the mark's house, which may be too cute and at 14 points leaves the arrow no room.

## Consequences

- The counts still move when the branch's name changes length, which is what we held against icons after the branch. It matters less here, because they show only when there's something to do, and they sit next to the name the user is reading.
- A branch with nothing to do shows no action at all, so Pull and Push carry no identity at rest, and Fetch and New Branch always take a click through the menu.
- `titleRowWidth` has to reserve room for the counts. In a narrow column the commit count goes first, then the branch's name truncates, and the counts stay.
- The icons have to be custom symbols, so that they follow the system's weights like the SF Symbols around them. They exist only as drawings for now, and a final name and brand haven't been chosen ([design exploration](../design/README.md)).
- Orange in this row sits alongside orange for uncommitted files and tags. Using it only when a click would run keeps it to the idea that color means something needs you.
- The refs panel shows `↑` before `↓`, and this row shows `↓` before `↑`, because you pull before you push. One of them has to change when this is built.
- Where a new worktree's folder goes is still to be decided. The popover's `../fix-retry` is only a placeholder.
- The shortcuts are drafts, chosen because nothing uses them today: Shift-Command-L to pull, Shift-Command-P to push, Shift-Command-E to fetch and Shift-Command-B for a new branch.
- The counts are only as fresh as the last fetch, which [decision 20](0020-fetch-when-yaga-becomes-active.md) deals with.
