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

## Still to decide

- **How the sidebar marks the exceptions:** A's initials, B's domain, or C's email on an organization's label.
- **How history marks a signed commit,** and how the commit panel says what checking the signature found, as the History board draws.
- **The Identity section of Settings › Git,** with the list of repositories that commit as someone else.

## Regenerating the boards

Read `project/canvas.json` from the canvas into a folder first, so that the merge starts from what's live, then:

```bash
uv run docs/design/commit-identity/boards.py --out <folder> --canvas <folder>/project/canvas.json
```

It writes the `Id-*.dc.html` boards into `<folder>/project/` and replaces the Commit identity page's boards and notes in that `canvas.json`, leaving every other page alone. Publish those files to the canvas.
