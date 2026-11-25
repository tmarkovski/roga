# 105. Show who commits go out as at the end of the title row, and always in the box

Accepted on 2026-11-24. This changes where [decision 103](0103-show-who-commits-go-out-as-from-git-config.md) shows the commit identity, and how it's drawn. It moves the identity from the branch row to the end of the title row from [decision 96](0096-draw-the-title-row-at-44-points.md), which holds the worktrees as tabs from [decision 95](0095-a-repositorys-worktrees-as-tabs.md). It shows the message box's line all the time, draws a person in place of the initials everywhere, and leaves the theme's nearly gray lane out of the email's tint. The rest of decision 103 still holds: reading the identity from git config, the popover, the warnings, Settings › Git, and which repositories the sidebar marks.

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
- **Someone else,** whose name or email differs from the global identity, is the same person in the email's tint, the lane color decision 103 picks by the email.
- **An identity whose next commit would go wrong** is an amber person, with a triangle at its lower right.

None of them has a circle. A circle's faint fill turned muddy on the button's gray, under the pointer and while the popover is open, and without one the person looks the same in the title row, the box's line and the sidebar: gray for the global identity, and in color for anyone else.

**The tint leaves out the nearly gray lane.** Decision 103 picks the email's tint from the theme's lane colors. Monokai's Stone and Xcode's Slate are nearly gray, so a repository that commits as someone else in one of them would look like it commits as the global identity. The tint comes from the other lanes, which are told apart by how saturated their light values are, so an email keeps its color in both appearances.

**A small shield** sits at the person's lower right while commits are signed, in the person's color. Its circle is cut out of the person, so the button's gray shows through it under the pointer. The box isn't there in a clean worktree, and a rebase or a cherry-pick signs each commit again, so the title row says it too. Not signing gets no mark, as on decision 103's initials, since most people don't sign, and the triangle takes the shield's place when a commit would go wrong. Its tooltip and its popover are decision 103's. The title row is there whatever the panels show, so the identity can be seen and changed in a clean worktree, before a merge or a rebase, or while an agent works. Nothing shows until git config has answered.

**The message box always says who.** The line at its top shows in every repository, with the person icon it had, the name, the email, and whether commits are signed. For the global identity, the whole line is gray. For anyone else, the person takes the email's tint and the name is in ink, so an exception still stands out. Until git config has answered, the box keeps the line's 22 points empty, so the message doesn't move down when the line arrives. The warnings take the line's place, as before.

**The branch row has nothing** about the identity.

**The sidebar and Settings draw the person.** A repository that commits as someone else has the person in the email's tint just before its count, where it had the initials, and so does its row in Settings › Git's list, at the size the box's line draws it. Neither has the shield, since it would sit on every row that signs and say the same thing many times over.

## Consequences

- Who commits, merges and rebases go out as is in view in every worktree, whatever the panels show, and changing it doesn't wait for a commit.
- The box's line costs 27 points of the message's height in every repository, where decision 103 spent them only on the exceptions.
- The branch row gets back the 34 points that the initials took, for the agent's line and the branch's name.
- The title row's person takes 40 points from the tabs, which get narrower sooner when there are many worktrees.
- Initials appear nowhere, so `CommitIdentity.initials` is gone.
- In the title row, only the person's color tells someone else from the global identity. The tooltip and the box's line say it in words.
- Every email's tint changed with the lane left out, and two emails are more likely to share one, with seven lanes to pick from instead of eight.
- Creating a branch or a worktree doesn't use the identity: git writes it only into the local reflog. A push goes out as the account that the SSH key or the credential helper belongs to, which Roga doesn't show.
- Since the identity is read in the git directory, as decision 103 says, every tab shows the same person. If Roga ever reads a linked worktree's own `config.worktree` or `includeIf "onbranch:"`, the identity would belong on each tab rather than at the end of the row.

## Alternatives considered

- **D alone, with nothing in the header.** A clean worktree would then show the identity nowhere but Settings.
- **E, the initials at the end of the tabs row, only for exceptions.** It would match the sidebar, but the global identity would show nowhere outside the box, and the initials say less than a tinted person.
- **F, beside history's number of commits.** It sits with history's commands, so it would read as a filter for whose commits history shows, and it would be the first thing cut when the row is short of room.
- **The email beside the person in the title row.** It reads without a hover, but it takes about 150 points from the tabs, which need them most when agents have many worktrees open. The box and the tooltip have the email.
- **No mark for signing in the title row,** leaving it to the tooltip and the box. A clean worktree has no box, and a rebase there would sign every commit it replays without anything in view saying so.
- **A circle in the email's tint behind someone else's person,** at 22 points in the title row and 18 in the sidebar. It told someone else from the global identity by its shape as well as its color, but its faint fill blended with the button's gray under the pointer and with a selected sidebar row's, and in a gray lane it read as a gray disc.
- **A ring in the email's tint around the person,** with no fill. It keeps a shape apart from the global identity's without going muddy, but it reads as a picture of someone among the row's thin icons, and in the sidebar it made the person smaller and crowded the count.
- **A crossed shield when commits aren't signed,** as the box's line has. Most people don't sign, so it would sit on nearly every repository and say little.
