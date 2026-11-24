# 105. Show who commits go out as at the end of the title row, and always in the box

Accepted on 2026-11-24. This changes where [decision 103](0103-show-who-commits-go-out-as-from-git-config.md) shows the commit identity, and how it's drawn. It moves the identity from the branch row to the end of the title row from [decision 96](0096-draw-the-title-row-at-44-points.md), which holds the worktrees as tabs from [decision 95](0095-a-repositorys-worktrees-as-tabs.md). It shows the message box's line all the time, and draws a person in place of the initials everywhere. The rest of decision 103 still holds: reading the identity from git config, the popover, the warnings, Settings › Git, and which repositories the sidebar marks.

## Context

Once decision 103 was built, the initials in the branch row looked out of place. The branch row is about one branch, while the identity belongs to the whole repository, and every worktree of a repository shows the same one. The initials also said little: a name rarely changes, and the email, which is what does change between work and personal repositories, showed only as the circle's tint.

The line in the box turned out to be the useful part, since it's where a commit is made and a click there changes who it goes out as. But the box can't be the only place that says who:

- **The box isn't always there.** It shows only while the worktree has uncommitted files and their row in history is selected. A clean worktree has no box.
- **Commits aren't the only thing that use the identity.** A merge that isn't a fast-forward writes a merge commit as the identity. A rebase or a cherry-pick keeps each commit's author but makes the identity its committer, and signs it again when signing is on. A revert writes a commit, and a pull that merges or rebases does what a merge or a rebase does.
- **Agents use it while nobody is looking at the box.** An agent runs git in its worktree with the repository's config, so its commits and merges go out as the same identity, and with SSH signing on and no key, its commits stop at signing.

The Commit identity page of the design canvas drew the options, and its generator is in [`docs/design/commit-identity`](../design/commit-identity):

- **D** shows the box's line all the time, with the initials at its start, and nothing in the header.
- **E** puts the initials at the end of the tabs row, and **F** puts them beside history's number of commits.
- **G** puts a person icon at the end of the tabs row, all the time, keeps D's line with the person icon the line already had, and marks the sidebar's exceptions with the same person.

We chose G.

## Decision

**The end of the title row says who the repository's commits go out as.** After the tabs, at the right end of the middle's part of the title row and before the refs panel's button while that panel is hidden, a 32-point icon button shows a person:

- **The global identity,** with nothing wrong, is a plain person icon in the gray of the row's other icon buttons.
- **Someone else,** whose name or email differs from the global identity, is a person in a 22-point circle in the email's tint, the lane color decision 103 picks by the email.
- **An identity whose next commit would go wrong** is an amber person in a faint amber circle, with a triangle on it.

It has no shield, since the tooltip and the box say how commits are signed. Its tooltip and its popover are decision 103's. The title row is there whatever the panels show, so the identity can be seen and changed in a clean worktree, before a merge or a rebase, or while an agent works. Nothing shows until git config has answered.

**The message box always says who.** The line at its top shows in every repository, with the person icon it had, the name, the email, and whether commits are signed. For the global identity, the whole line is gray. For anyone else, the person takes the email's tint and the name is in ink, so an exception still stands out. Until git config has answered, the box keeps the line's 22 points empty, so the message doesn't move down when the line arrives. The warnings take the line's place, as before.

**The branch row has nothing** about the identity.

**The sidebar and Settings draw the person.** A repository that commits as someone else has the tinted person in an 18-point circle just before its count, where it had the initials, and so does its row in Settings › Git's list.

## Consequences

- Who commits, merges and rebases go out as is in view in every worktree, whatever the panels show, and changing it doesn't wait for a commit.
- The box's line costs 27 points of the message's height in every repository, where decision 103 spent them only on the exceptions.
- The branch row gets back the 34 points that the initials took, for the agent's line and the branch's name.
- The title row's person takes 40 points from the tabs, which get narrower sooner when there are many worktrees.
- Initials appear nowhere, so `CommitIdentity.initials` is gone.
- Creating a branch or a worktree doesn't use the identity: git writes it only into the local reflog. A push goes out as the account that the SSH key or the credential helper belongs to, which Roga doesn't show.
- Since the identity is read in the git directory, as decision 103 says, every tab shows the same person. If Roga ever reads a linked worktree's own `config.worktree` or `includeIf "onbranch:"`, the identity would belong on each tab rather than at the end of the row.

## Alternatives considered

- **D alone, with nothing in the header.** A clean worktree would then show the identity nowhere but Settings.
- **E, the initials at the end of the tabs row, only for exceptions.** It would match the sidebar, but the global identity would show nowhere outside the box, and the initials say less than a tinted person.
- **F, beside history's number of commits.** It sits with history's commands, so it would read as a filter for whose commits history shows, and it would be the first thing cut when the row is short of room.
- **The email beside the person in the title row.** It reads without a hover, but it takes about 150 points from the tabs, which need them most when agents have many worktrees open. The box and the tooltip have the email.
- **A shield on the person when commits are signed,** as decision 103 had on the initials. The box and the tooltip already say it, and a mark on every repository that signs would be noise.
