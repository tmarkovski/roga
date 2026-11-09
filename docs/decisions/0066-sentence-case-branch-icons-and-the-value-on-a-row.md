# 66. Sentence case, branch icons and the value on a row

Accepted on 2026-11-09. This changes the wording of the rows in [decision 65](0065-one-menu-for-a-commit-or-a-branch.md), and extends what [decision 29](0029-dialogs-that-say-what-happens-and-show-the-command.md) says about sentence case from dialogs to menus.

## Context

The menus mixed two casings, with Check Out This Commit beside Cherry-Pick into main and Reset main to Here…. Rows that name two branches were hard to read, because nothing marked which of their words were branches. The list's menu spent five rows and two headings on two settings. And nothing in Roga could say which remote a branch uses, or change it, when a repository has more than one.

## Decision

**Menus in the window are in sentence case**, as dialogs already were. That covers the menus Roga draws, the ones SwiftUI draws from buttons in the window, and the choices in their pop-ups. Names keep their capitals, such as Finder, Terminal and `HEAD`.

**The menu bar stays in title case.** macOS fills it with rows of its own that we can't change, such as Enter Full Screen and Bring All to Front, so sentence case there would mix the two within a single menu. This means the same command can read New Worktree… in the menu bar and New worktree… in the window.

**A branch's name has the branch icon in front of it**, in headings and in the middle of rows, as in `Merge ⎇feature into ⎇main…`. `RefMenu.Title` holds the words and the branch names apart, and is written as `"Merge \(branch: name) into \(branch: head)…"`. The icon is an attachment in the row's text, so a name that's too long is cut short along with it, and VoiceOver reads only the words. `HEAD` on a detached commit gets no icon, because it isn't a branch.

Only rows Roga draws can do this. An `NSMenuItem` could take an attachment in its `attributedTitle`, but SwiftUI's `Menu` builds its items itself and offers only one icon at the front. So the title row's branch menu has none in its text. The worktree chooser's rows have their own icon in a column.

**A row that opens a set of options says which is chosen**, dimly, before its arrow. **Group by** and **Sort by** in the list's menu are now two rows like that, in place of two headings and their options. Arrows are dim on every row, to match.

**Set upstream says which remote a local branch pushes to and pulls from**, by name, with the choices in a submenu. A remote's URL is in the refs panel already. It's on the current branch's menu after Fetch, and on another branch's after Remote. It's only offered when the repository has two or more remotes.

Choosing a remote only changes git's settings for the branch, so it doesn't ask first and doesn't reach the network:

- When the remote has the branch, it runs `git branch --set-upstream-to`, by the ref's full name, because a local branch could be called `fork/x` too. The branch keeps tracking the name it tracked, if the new remote has that, and otherwise tracks its own.
- When the remote hasn't got the branch, it runs `git branch --unset-upstream`, so that a pull doesn't keep coming from the old remote, and the first push goes to the one that was chosen and sets up tracking. Publishing is left to that push, because choosing a row shouldn't put a branch on someone's server.
- Either way it sets `branch.<name>.pushRemote`, because a repository's `remote.pushDefault` would otherwise send the pushes somewhere else.

A branch with neither says **None**.

## Consequences

- One more `git remote` runs each time history loads, beside the `git for-each-ref` from decision 65. A remote added on the command line shows up the next time history loads.
- Someone who deliberately pulls from one remote and pushes to another will have both pointed at the same remote if they choose one here. The row shows the remote it pulls from.
- The title row's branch menu doesn't have Set upstream, since SwiftUI's menus can't show a value at the end of a row.
