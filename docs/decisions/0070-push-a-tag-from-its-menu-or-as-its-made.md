# 70. Push a tag from its menu, or as it's made

Accepted on 2026-11-09. This adds to what [decision 65](0065-one-menu-for-a-commit-or-a-branch.md) says a tag's menu holds, and gives the refs panel's tags the menu their badges have.

## Context

Create › Tag here… made a lightweight tag, and every push Roga knew was for a branch, so a tag made in Roga couldn't leave the Mac without the command line. That matters for Roga itself, whose releases start when a `v*` tag reaches GitHub. `git push --follow-tags` wouldn't help, because it only pushes annotated tags, and `--tags` would push every tag in the repository, including ones someone meant to keep to themselves.

## Decision

**A tag's menu has Remote › Push to origin**, naming the remote it goes to. That's the tag's badge in history and its row in the refs panel's Tags, which now builds the same menu as the badge, as branches already did. A tag on something other than a commit, such as a tree, still offers only Copy name.

**The New Tag popover has a Push to origin checkbox**, under the name. It starts unchecked every time the popover opens, because pushing a `v*` tag can start a release, and a checkbox that remembered being checked would do that by surprise. While it's checked, the command under the name gains a second line with the push.

**Only that tag goes, by its full name:** `git push origin refs/tags/v0.0.1`. The full name keeps git from pushing a branch with the same name instead, or refusing because the name matches both.

**The remote is where the current branch pushes**, which follows `branch.<name>.pushRemote` and `remote.pushDefault`, as a branch's first push does. With `HEAD` detached there's no branch to go by, so it's `origin`, or the only remote there is. With several remotes and no `origin`, nothing is offered.

**A push shows and fails the way a branch's does.** The title row says Pushing… with the house, then `Pushed v0.0.1`. When git refuses, as it does when the remote has a tag of that name on another commit, the dialog is titled `Can't push v0.0.1` and shows the command and what git said, which for that case includes `already exists`. A push from the popover whose tag was made but couldn't be pushed is titled `Made v0.0.1, but can't push it`, as adding a remote that can't be fetched from is. A remote that has the tag on the same commit already says it's up to date, and Roga says Pushed.

## Consequences

- The refs panel builds each row's menu as it draws, but whether `HEAD` has a tag's commit means walking history from `HEAD`, which can take milliseconds for an old tag in a large repository. So a tag's row looks for that only as its menu opens. Assistive apps get the menu without it, which offers Cherry-pick unless the commit is `HEAD`'s, and the dialog says if `HEAD` has it.
- Roga doesn't know which tags a remote has, since tags have no remote-tracking refs, so Push to origin is offered for tags the remote has already.
- There's no way to choose another remote for a tag, or to delete one from a remote, yet.
