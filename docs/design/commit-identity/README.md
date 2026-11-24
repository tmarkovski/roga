# Commit identity

Boards for showing who a repository's commits go out as, and whether they're signed, read from git config and changed with `git config` rather than with profiles that Roga keeps ([issue 115](https://github.com/tmarkovski/roga/issues/115)). They're on the Commit identity page of the design canvas [yaga layout options](https://claude.ai/artifact/4WQVua6gwKqSBoiRdf2FhX), and [`boards.py`](boards.py) draws every board.

The boards draw one person, Sam Rivera, whose `~/.gitconfig` commits as `sam@rivera.dev` and signs with an SSH key, and whose `~/.gitconfig-work`, which `~/.gitconfig` includes for `~/work/`, commits as `sam.rivera@acme.com`. The middle column is 680 points wide, as in the default window, and the commit panel 320. The message box is drawn as `CommitBox.swift` lays it out after [decision 98](../../decisions/0098-buttons-in-a-row-under-the-message.md), without the canvas's card.

The page has today's window, then three options for the branch row and the message box:

- **A** draws the identity as initials in a circle tinted by the email, before Fetch and before Commit, with a small shield when commits are signed. It costs no height, but at 320 points Generate loses the agent's name to make room.
- **B** writes the email before Fetch, and puts a line at the top of the box with the name, the email and whether commits are signed. It's the clearest, and the line costs 27 points.
- **C** shows nothing while the identity is the global one and nothing is wrong, and says it in the branch chip's menu and Commit's tooltip. A repository that commits as someone else shows its email as B does.

After those come every option in seven moments in both appearances, the identity popover in eight frames, a board to try the popover, three ways to mark the sidebar's exceptions, Settings › Git with an Identity section and a list of the repositories that commit as someone else, and how history and the commit panel show signed commits.

Every option warns the same way, at the top of the box where decision 98 puts what's wrong: when there's no email, so git would refuse to commit or make one up, and when signing is on with no key, so the commit would stop at signing.

## What was decided

[Decision 103](../../decisions/0103-show-who-commits-go-out-as-from-git-config.md) took A in the branch row, and B's line in the box only while the identity isn't the global one, which is C's rule. An unsigned identity gets no mark on the initials, and the box's line says Not signed. At the box's default 320 points, the line drops the words Signed and Not signed before it cuts the email, which the boards don't draw. `shield` and `shield-off` are in `docs/design/icons/lucide` now, and the boards still draw them by hand.

The sidebar uses A's initials for the exceptions, without the shield, and Settings › Git has the Identity section and the list of repositories that commit as someone else, as the Settings board draws them.

[Decision 104](../../decisions/0104-mark-signed-commits-and-check-only-the-selected-one.md) took the History board's shield, after the short ID rather than before it, and the commit panel's Signature line, which also says when a key isn't trusted or has expired. `shield-check`, `shield-alert` and `shield-question-mark` are in `docs/design/icons/lucide` too.

[Decision 105](../../decisions/0105-show-who-commits-go-out-as-at-the-end-of-the-title-row.md) took G, described below: the person at the end of the tabs row, the box's line all the time, and the tinted person in place of the initials in the sidebar and Settings.

## After building it

Once decision 103 was built, the initials in the branch row looked out of place, since the row is about the branch and the identity belongs to the whole repository. Commits also aren't the only thing that use the identity. A merge that isn't a fast-forward, a rebase, a cherry-pick, a revert and a pull that merges or rebases all write it into history, and agents run git in their worktrees with the same config. The commit box shows only while a worktree has uncommitted files, so it can't be the only place that says who. The page now starts with **G**:

- **G** puts a person icon at the end of the tabs row, which holds every worktree of the repository. It's a plain gray icon for the global identity, a circle in the email's tint for anyone else, and amber with a triangle when a commit would go wrong, and a click opens the identity popover. The box keeps its line all the time with the person icon it has now, gray for the global identity and in the email's tint with the name in ink for anyone else, and the branch row has nothing. The initials are gone everywhere, since a name rarely changes and the email gives the tint.
- **Seeing and changing it without a commit** draws the tooltip, a clean worktree with no box, the popover opened from the tabs row, and the sidebar, which marks its exceptions with the same tinted person.
- **G, moment by moment** draws the end of the tabs row and the box in the seven moments, in both appearances at 320 points. Before git config has answered, the tabs row shows nothing and the box keeps the line's room empty.

After G come the two boards that led to it. **D** showed the box's line all the time, with the initials at its start, and nothing in the header. **Where the initials could go** compared D with **E**, at the end of the tabs row, and **F**, beside history's number of commits.

## Regenerating the boards

Read `project/canvas.json` from the canvas into a folder first, so that the merge starts from what's live, then:

```bash
uv run docs/design/commit-identity/boards.py --out <folder> --canvas <folder>/project/canvas.json
```

It writes the `Id-*.dc.html` boards into `<folder>/project/` and replaces the Commit identity page's boards and notes in that `canvas.json`, leaving every other page alone. Publish those files to the canvas.
