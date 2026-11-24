# 103. Show who commits go out as, from git config

Accepted on 2026-11-24. This puts the commit identity in the branch row from [decision 95](0095-a-repositorys-worktrees-as-tabs.md) and at the top of the message box from [decision 98](0098-buttons-in-a-row-under-the-message.md), and adds a popover that changes it with `git config` and shows the command, as [decision 29](0029-dialogs-that-say-what-happens-and-show-the-command.md) asks of dialogs. It marks the repositories that commit as someone else in the sidebar, beside the count from [decision 58](0058-the-mark-under-the-menus-button-and-the-count-before-it.md) and on the second line from [decision 48](0048-a-second-line-under-a-sidebar-row-while-theres-something-to-say.md), and adds the global identity to Settings › Git. It reads the identity with the sidebar's look from [decision 99](0099-bring-a-sidebar-rows-details-in-as-they-load.md). Issue [115](https://github.com/tmarkovski/roga/issues/115) describes the whole feature.

## Context

Roga didn't say which name and email a commit would carry, or whether it would be signed, until the commit was made and the commit panel showed its author. On a Mac with both work and personal repositories, that's easy to get wrong, and an agent in a worktree commits with whatever the repository's config says, perhaps many times before anyone reads an author line.

Some git apps keep profiles of their own and apply them to repositories. git already has a way to do that, `includeIf "gitdir:~/work/"` with a file of its own, and a profile that Roga kept could disagree with what the command line does, which "Git is the source of truth" in [VISION.md](../../VISION.md) rules out.

The Commit identity page of the design canvas drew the branch row and the message box at their real sizes, in seven moments and both appearances, and its generator is in [`docs/design/commit-identity`](../design/commit-identity). It compared three options:

- **A** draws the initials in a circle tinted by the email, before Fetch and before Commit, with a small shield when commits are signed.
- **B** writes the email before Fetch, and puts a line at the top of the box with the name, the email and whether commits are signed.
- **C** shows nothing while the identity is the global one and nothing is wrong.

We chose A in the branch row, and B's line in the box only while the identity isn't the global one, which is C's rule.

For the sidebar, the page drew three ways to mark a repository that commits as someone else: A's initials at the right of the row, B's email domain after the name, and C's email on an organization's label when every repository under it shares one. We chose A's initials, so that the same mark means the same thing in the branch row and the sidebar.

## Decision

**git config is the only place the identity is kept.** Roga reads `user.name`, `user.email`, `commit.gpgsign`, `gpg.format` and `user.signingkey`, and `gpg.ssh.defaultKeyCommand`, which decides whether SSH signing works without a key, with one command in the git directory that every worktree shares:

```bash
git config -z --show-scope --show-origin --get-regexp '^(user\.(name|email|signingkey)|commit\.gpgsign|gpg\.format|gpg\.ssh\.defaultkeycommand)$'
```

It takes about 10 milliseconds, nearly all of it starting git, so nothing is cached on disk. `--show-scope` and `--show-origin` say where each value came from, which the tooltip and the popover say in words, as in `from ~/.gitconfig-work, which ~/.gitconfig includes` or `this repository's own`.

- **When it's read:** with the sidebar's first look at a repository, off the launch path, so it never holds up the list or history. Until it's read, nothing shows.
- **When it's read again:** when the repository's config changes, which its watcher already notices, and right after Roga writes. When Roga becomes active, it reads every repository's identity again if `~/.gitconfig`, the config in `~/.config/git`, or a file they included for any repository has changed since, by the file's modification date, because no session watches files outside its repository.
- **The global identity** is what git says outside any repository, which Roga reads from `/`. A repository commits as someone else when its name or email differs from that one, comparing emails without case. Comparing the values rather than where they came from means that an identity kept in a file that `~/.gitconfig` includes for every repository isn't an exception, while one that `includeIf` gives `~/work/` is.

**The branch row shows the initials before Fetch.** They're in a 22-point circle, from the first letters of the name's first two words, or of the email when there's no name. The circle takes one of the color theme's lane colors, picked by the email, so a work identity and a personal one look different and keep their colors from one launch to the next. A small shield sits on the circle when commits are signed, an amber triangle when a commit would go wrong, and nothing when commits aren't signed, since most people don't sign. The tooltip has the name and the email, where the email comes from, and how commits are signed, with the key. A click opens the popover. A bare repository shows nothing, since nothing is committed in it.

**The message box says who only when it's someone else.** While the name or the email differs from the global identity, a line at the top of the box, where decision 98 puts what's worth knowing about the commit, says `Sam Rivera <sam.rivera@acme.com>`, then a shield and Signed, or a crossed shield and Not signed. When the panel is too narrow for all of it, as at its default 320 points with a long email, the words for signing go before the email is cut, and the shield stays. A click opens the popover. With the global identity, the box says nothing, since the initials already do.

**The box warns before a commit that would go wrong.** On an amber card at the top of the box:

- **With no email,** it says `No email to commit with`, because git would refuse to commit or make one up from the login and the Mac's name, and offers Set Identity….
- **With SSH signing and no key,** that is, with no `user.signingkey` and no `gpg.ssh.defaultKeyCommand`, it says `Signing is on, but there's no key`, because the commit would stop at signing, and offers Set Key… and Stop Signing, which runs `git config --local commit.gpgsign false`. OpenPGP and X.509 pick a key from the email, so they don't warn.

**The popover changes the identity with `git config`.** It's titled Commit identity, "For roga and every worktree of it". It has Name and Email, and a Sign commits switch with the format, OpenPGP, SSH or X.509, and the key under it while it's on. Each field says where its value comes from, and once it changes, where Save will put it.

- **Save to** chooses **This Repository**, which runs `git config --local` and is the default, or **Every Repository**, which runs `git config --global`. Writing the global config from one repository's popover changes every repository that inherits it, so it's never the default.
- **Use Global** shows beside a value that the repository sets itself, and runs `git config --local --unset` for it. A field that's emptied is unset where Save writes.
- **The block along its bottom** shows exactly what Save runs, one command per changed setting.
- **When saving to every repository wouldn't change this one,** because the repository, its worktree or a file included for it sets the value, the popover says so above its buttons. Save still works, since it changes the other repositories.

**The sidebar marks only the exceptions.** Most repositories commit as the global identity, so a name or an email on every row would repeat one thing and crowd the counts and the agents' marks.

- **Someone else:** a repository whose name or email differs from the global identity has its initials in an 18-point circle, in the email's tint, just before its count. The tooltip is the branch row's. The circle has no shield, since a selected or hovered row's fill would show around the shield's circle, and the branch row says how commits are signed.
- **A commit that would go wrong:** the row gets a second line in amber, after a triangle: `No email for commits` or `Signing needs a key`. It comes after everything else a second line says, an agent that waits, stopped work or an agent at work, since it stays until the config is fixed.
- **A bare repository** gets neither, since nothing is committed in it. VoiceOver reads the row's identity, as in `Commits as sam@oss.example`.

**Settings › Git has the global identity.** An Identity section follows Installation, with Name, Email and Sign commits, and the format and the key while signing is on, as the popover has them. Each row says its key and where its value comes from, as in `user.email · from ~/.gitconfig`. A change runs `git config --global` at once: a field's when Return is pressed or the field is left, and the switch's or the format's as it changes, and an emptied field is unset. Every repository's identity is read again after it.

Under it, **Repositories that commit as someone else** lists each repository whose identity is an exception, with its email and where that comes from. Repositories that a file outside them gives the same identity, such as every repository in `~/work/`, share a row, since they change together. A repository's own name or email has Use Global, which runs `git config --local --unset`, and a repository whose commits would go wrong has Set…, which opens the identity popover. With no exceptions, it says that every repository in the sidebar commits as the global identity.

## Consequences

- Who an agent's commits and yours go out as is in view before either of you commits, and a repository with an exception says so in the box, where a commit is about to happen.
- The branch row's right end takes 34 more points, so the agent's line and the branch's name are cut a little sooner.
- Roga doesn't write `includeIf` rules. Giving a folder of repositories an identity still means editing `~/.gitconfig`.
- Roga reads the identity in the git directory, which git treats as the main worktree. A linked worktree's own `config.worktree`, with `extensions.worktreeConfig`, and `includeIf "onbranch:"` for a linked worktree's branch aren't read for that worktree. The popover shows a worktree's own value as such but doesn't change it.
- A file that starts to count only after its include changes, such as one created where an existing `includeIf` points, is read again only once something Roga watches changes.
- A sidebar row with initials gives its name 24 fewer points before it fades, and the initials don't line up in a column, since they sit just before a count that comes and goes.
- Settings writes the global config with no Save, as its other settings change at once. A field that's left half typed is written as it stands.

## Alternatives considered

- **B in both places.** It's the clearest, but its line costs the box 27 points of height in every repository, and the email before Fetch takes about 150 points of the branch row, where the agent's line from [decision 100](0100-say-what-the-worktrees-agent-is-doing-in-the-branch-row.md) needs them.
- **C alone.** It's the quietest, but nothing would say who commits go out as with the global identity, short of opening a menu. The initials cost 34 points and give the popover somewhere to hang from.
- **A in the box too, before Commit.** At the box's default 320 points it costs Generate the agent's name, which is the first thing decision 98's row gives up when it's short of room.
- **Telling someone else apart by where the values came from.** An identity kept in a file that `~/.gitconfig` includes for every repository would then look like an exception in every repository.
- **Profiles that Roga keeps.** They'd be state that can disagree with git, for what `includeIf` already does.
- **The email's domain after a sidebar row's name.** It reads without a hover, but it takes the place of the branch, which the row already cuts short in a narrow sidebar.
- **The email on an organization's label.** It says it once for a whole folder of work repositories, but only when every repository under the label shares it, and the sidebar can list repositories without groups.
