# 35. One cloud on a badge for each remote that has the branch

Accepted on 2026-11-04. This changes one part of [decision 23](0023-one-badge-for-a-branch-and-its-upstream.md), which gave another remote's branch of the same name a badge of its own. The rest of that decision still holds.

## Context

Decision 23 gave a branch and its upstream one badge, with a cloud after the name. A repository pushed to two remotes, as when a team works in one place and mirrors to another, still got two badges for what is one branch in sync everywhere: `main` with a cloud, and then `main | origin`. With a few branches on a commit, those second badges took the room the subject needs, and they said little that the first badge couldn't.

## Decision

**A badge has one cloud for each remote it stands for.** A branch that shares a badge with its upstream also takes in every other remote's branch of the same name on that commit, and their separate badges go. The clouds sit side by side after the name and all look the same, so the upstream's isn't set apart.

**The clouds start with the upstream.** A branch whose upstream isn't on the commit has no cloud, as in decision 23, so a branch that has moved away from its upstream still loses its cloud, even if another remote has the same commit. That remote's branch keeps its own badge, and so does any remote's branch next to a branch that tracks nothing.

**Remote branches with no local branch beside them stay as they are.** `main | origin` and `main | upstream` are still two badges when no local `main` is on the commit. A cloud only stands in for a remote's name next to a local branch. Merging these would hide which remote is which, and double-clicking would have to choose one of them to check out.

**Everything in words still names each one.** The tooltip and VoiceOver list them, upstream first, as in `main, current branch, in sync with beckwayops/main and origin/main`. In the row's menu, each other remote's branch keeps its own row with **Delete from Remote…**, as it had when it had a badge. The **Delete…** dialog for a branch and its upstream still only asks about those two, and double-clicking the badge still checks out the local branch.

**A badge cut short keeps the clouds that fit.** The name gives way first, as it does in decision 23, and clouds that would fall outside the badge aren't drawn.

## Consequences

- The row says how many remotes have the branch, but not which ones. The tooltip, the menu and the refs panel say which.
- Each remote adds a cloud's width to the badge, which comes out of the room for the subject. That's still narrower than the badge it replaces, which repeated the branch's name.
- A remote whose name has a slash in it keeps its own badge, for the same reason as in decision 23: a ref's name alone can't say where the remote's name ends.
- Finding the other remotes only happens for a commit that has a branch's upstream on it, and it takes time in proportion to the refs on that commit. It hasn't been measured on a repository with many refs.
