# 121. Delete a folder of branches, or the branches picked with Command and Shift

Accepted on 2026-11-27. This adds a menu to a folder of local branches in the refs panel, from [decision 50](0050-branches-in-folders-at-each-slash-of-their-names.md), and lets Command-click and Shift-click pick several local branches there. Both delete through the dialog that [decision 38](0038-one-delete-on-a-commit-with-its-branches-in-the-dialog.md) made for the branches on a commit and [decision 119](0119-branches-on-one-line-and-what-the-pointer-lights-up.md) opened to the merged branches, which now counts exactly what any mix of branches on different commits would lose.

## Context

Agents make a lot of branches, and people tend to keep them under a prefix such as `tm/` or `agent/`. Cleaning them up meant right-clicking each one and picking Delete branch, one at a time, and waiting for a dialog whenever one had commits of its own. The button on the Branches heading only deletes the branches that are merged, so a folder of abandoned experiments, which are never merged, had no faster way out.

The dialog that the merged branches use already listed any number of branches with a switch for each. But it counted lost commits as if the branches were all on one commit, where any branch that stays keeps everything. That holds for the branches on one commit and nearly always for merged ones, and it doesn't hold for a folder, where each branch can have commits of its own and two branches can share commits that nothing else has, as when one was made from the other.

## Decision

**Right-clicking a folder of local branches** opens a menu with the folder's path as its heading and **Delete 4 branches…**, which counts the branches in the folder that git can delete. A branch that's checked out here or in another worktree isn't counted, and the command is disabled when that leaves none. While the filter has text, the folder holds only its matches, and the command deletes only those. A folder of a remote's branches has no menu, since deleting from a remote affects everyone who uses it.

**Command-click and Shift-click pick local branches**, as in a Finder list. Command-click adds a branch to what's picked, or takes it out, and the first one also picks the branch that was selected. Shift-click picks every local branch row from the last one clicked without Shift to this one, in the order the rows show. History shows the commit of the branch clicked last. A plain click, the arrow keys, Escape, or a change to the filter lets go of what's picked, and a branch that's gone is no longer picked. A double-click with Command or Shift held doesn't check the branch out. Remote branches, tags and stashes can't be picked.

**Right-clicking a picked branch** opens a menu with how many are picked as its heading and **Delete 4 branches…**, counted the same way as a folder's. Right-clicking a branch that isn't picked opens its own menu, as before.

**The main branch stays.** Deleting several branches never deletes the main branch, the one that `RefList.mainBranch` names and that branches are reviewed against. It isn't counted in either menu, and when it's among the branches picked, the dialog leaves it out and says `main is the main branch and will be kept.` Picking `main` along with branches that are done with is easy with Shift-click, and deleting it with them is never what someone means. Its own menu still deletes it.

**Both open the dialog with a switch for each branch, all on**, since someone asked for those branches by name. It's titled **Delete the branches in tm/?** for a folder and **Delete 4 branches?** for the branches picked. A branch that's checked out stays, and the dialog says so under the switches, as it does for the branches on a commit. When every branch is checked out or is the main branch, there's nothing to ask, and a message says why each one stays.

- **Each switch says what that branch has on its own:** `3 commits aren't on any other branch or tag.`, `Some of its commits are only on branches in this list.` for a branch whose commits stay only while another branch here stays, or `Its commits are all on other branches or tags.`
- **The card of commits counts exactly what the switches lose.** Roga lists the commits that go when every branch in the dialog goes with `git rev-list --topo-order --parents`, and works out which of the branches lead to each one by passing each branch down from its tip to the parents. That gives a count for each set of branches, such as 2 commits that `tm/base` and `tm/next` both lead to and 1 that only `tm/next` does. A commit goes only when every branch that leads to it goes, so turning a switch off adds up the counts again without asking git. The heading then says `These 3 commits would become unreachable`, `1 of these 3 commits would become unreachable`, or that they stay on the one branch switched off, or on `the branches switched off` when more than one is.
- The merged branches' dialog counts the same way. The branches on one commit need no listing, since every one of them leads to every commit.
- Delete turns red while anything would be lost. Deleting runs `git branch -D` for each branch in turn and stops at the first one git refuses, saying which went and which didn't, as for the branches on a commit.

## Consequences

- Opening the dialog for branches on different commits runs one more `git rev-list`, which lists every commit that deleting all of them would lose, rather than only counting them. That's a few dozen commits for a folder of feature branches. A branch with a long history of its own, such as one from an unrelated repository, makes the list as long as that history, though it's still a single command that the commit graph speeds up.
- Command-Delete already deletes the worktree from the menu bar, so picked branches have no key of their own for deleting. Right-clicking one is the way.
- The selection of a branch row and the picked branches are separate. The single selection is what history follows and what the arrow keys move. Picking is only for deleting together, and a plain click goes back to one.

## Alternatives considered

- **A dialog with no switches that deletes everything in the folder.** It's simpler, since there's one count to show, but someone who sees that one branch in the folder has work they want to keep would have to cancel, pick the others by hand, and start again.
- **Counting what each branch loses on its own and adding those up.** It's one `rev-list --count` for each branch, but it says nothing is lost when two branches that share their only copies of some commits both go, which is the case of a branch made from another branch in the same folder.
- **Counting again with git each time a switch flips.** It's exact, but the card would change after a delay, and the Delete button would have to wait for the count to come back before it could say whether it's red.
- **A switch for the main branch that starts off.** It would keep `main` safe by default, but the menu's count and the dialog's switches would disagree, and one stray click would still delete it along with the rest.
- **A folder menu for a remote's branches.** It would push a deletion to the remote for every branch in the folder, which affects everyone who uses it, and the remote branch's own Delete from remote… already asks about one at a time.
