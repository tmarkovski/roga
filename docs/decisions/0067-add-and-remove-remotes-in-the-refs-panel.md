# 67. Add and remove remotes in the refs panel

Accepted on 2026-11-09.

## Context

The refs panel listed remotes, but changing them took the command line. [Decision 66](0066-sentence-case-branch-icons-and-the-value-on-a-row.md) made choosing between remotes matter, since a repository only offers Set upstream with two or more.

## Decision

**A plus on the Remotes heading adds one**, and **Add remote…** on a remote's menu does the same. The plus stays there when a repository has no remotes yet, so that it can get its first.

**The dialog asks for a name, a pull URL and an optional push URL**, and shows the commands as they're typed ([decision 29](0029-dialogs-that-say-what-happens-and-show-the-command.md)): `git remote add`, `git remote set-url --push` when the push URL differs, and `git fetch`. The button stays disabled for a name that's taken, has a space or starts with a hyphen, and for a URL that starts with a hyphen, because git would take that for an option. The note under the fields says which. git decides the rest, such as `a..b`, and what it says goes in the usual dialog.

**Adding fetches straight away.** A remote with nothing fetched has no branches to show, and Set upstream would treat every branch as missing from it. It's also how a mistyped URL shows up at once. If the fetch fails, the remote stays, and the dialog is titled `Added fork, but can't fetch from it`, so it's clear how far it got.

**Remove… is on a remote's right-click menu and always asks**, in red, with the remote's name in the heading above it. The dialog says that nothing changes on the remote itself, how many remote branches go from here, and which local branches stop pushing and pulling there. `git remote remove` clears those branches' settings and `remote.pushDefault` by itself. A remote that has branches left but isn't configured any more has no Remove…, because git can't remove what isn't configured.

## Consequences

- What's typed lives on `BranchModel` rather than in the sheet. A button that Return presses can keep the action it had when it was first enabled, so a value captured in its action would be out of date. Testing this in the app caught the URL being saved with only its first character.
- The terminal block has a fixed height of five lines in this dialog, and scrolls past that, because a sheet can't grow as a URL gets longer.
- Changing an existing remote's URLs or name isn't here yet. A push URL that's already set isn't shown anywhere, since the panel reads only `remote.<name>.url`.
