# 104. Mark signed commits, and check only the selected one

Accepted on 2026-11-24. This adds a mark for signed commits to history's rows from [decision 7](0007-commit-list-is-an-nstableview.md), and a Signature line to the commit panel's people, under the author. It follows [decision 103](0103-show-who-commits-go-out-as-from-git-config.md), which shows whether the next commit will be signed, and finishes the part of issue [115](https://github.com/tmarkovski/roga/issues/115) about commits that are already made. Amended in place on 2026-11-25: the shield in history is larger and a step darker, with room kept for it and a tooltip, since at 9 points in the hash's gray it went unnoticed. [Decision 109](0109-keep-the-signature-line-in-place-and-let-checking-be-turned-off.md) changes how the Signature line looks while git checks and after, so that nothing under it moves, and adds a setting that turns the check off.

## Context

Issue 115 split signing into three questions, which cost very different amounts. Whether commits will be signed comes from git config, which decision 103 reads. Whether a commit is signed is in the commit itself, as a `gpgsig` header, which `CommitParser` already stepped over as it read each row's commit with `git cat-file`. Whether the signature is good takes a run of gpg, gpgsm or ssh-keygen for each commit, from a few milliseconds to most of a second, and history reads hundreds of rows' text as they scroll into view.

An SSH signature makes this harder. git can only check one against `gpg.ssh.allowedSignersFile`, which lists whose keys to trust, and most people who sign with SSH never set one up. So the most common answer for an SSH-signed commit is that git didn't check it, and git reports that with the same letter, `N`, as no signature at all.

The History board on the design canvas's Commit identity page drew a shield by the hash of every signed commit, and the commit panel's line in six states.

## Decision

**History marks a commit that carries a signature, without checking it.** `CommitParser` reads the first line of a `gpgsig` or `gpgsig-sha256` header, which says whether it's SSH's, OpenPGP's or X.509's, into `CommitInfo.signatureFormat`, at no extra cost. A signed commit's row has a shield just after its short ID, as tall as the short ID's digits and in the author's and date's gray, a step darker than the short ID, so that it can be seen at a glance without competing with the subject. The short ID's column always keeps room for it after the eight digits. It says the commit has a signature, not that the signature is good, and its tooltip says so: `Signed. Select the commit to check the signature.` VoiceOver reads "signed" after the short ID. A `mergetag` header is a merged tag's signature rather than the commit's, so it doesn't count.

**The commit panel checks only the commit it shows.** A signed commit gets a Signature line under its author and committer. It says Checking… until git answers, then a shield and a few words, with a gray line under them for who signed it and with what key, or why git couldn't tell:

- **Good** (`G`): `Good SSH signature`, in green, with the signer and the key.
- **Not trusted** (`U`): `Good signature, from a key this Mac doesn't trust`. For SSH, that means the allowed signers file doesn't list the key, and the line says so.
- **Not checked** (`N` for a signed commit): `Signed with SSH, not checked`, because git needs `gpg.ssh.allowedSignersFile` to know whose keys to trust. For OpenPGP or X.509, git couldn't run gpg or gpgsm.
- **Missing key** (`E`): `Signed with a key this Mac doesn't have`, with the key.
- **Expired** (`X` or `Y`): `Good signature, from a key that has expired`, in amber.
- **Revoked** (`R`) or **bad** (`B`): in red. A bad one reads `The signature doesn't match this commit`, because it was made for other contents, or with another key than it names.

The check is `git log -1 --no-show-signature --format=%G?%x00%GS%x00%GK` for the commit, in the git directory, so that the repository's own `gpg.ssh.allowedSignersFile` counts. It waits 150 milliseconds after the commit shows, so that moving through history with the arrow keys doesn't run gpg for every commit on the way, and a check still running stops when another commit shows. Nothing is cached, so a key or an allowed signers file added since shows the next time the commit is selected.

## Consequences

- A repository that signs every commit has a shield on every row. It's gray so that it doesn't compete with the subject, and a row's columns don't move for it, since the short ID's column is 76 points wide in every row, 4 more than it was, to keep room for it.
- The mark can't tell a good signature from a bad one in history. Selecting the commit does.
- Most SSH-signed commits read "not checked" until someone sets up an allowed signers file, and the panel says what git needs rather than guessing.
- `log.showSignature` in someone's config doesn't change what Roga reads, since the check asks for no signature output.
- Signed tags, and signatures in the refs panel, aren't marked.

## Alternatives considered

- **Checking every row's signature.** It would tell good from bad in history, but it would run gpg or ssh-keygen hundreds of times as history scrolls, which decision 7's budget for loading a row's text can't take.
- **A green check by the hash once a commit has been checked.** History would then mark the commits someone happened to select differently from the rest, which reads as if the others were worse.
- **A 9-point shield in the short ID's gray,** which was built first, so that it was as quiet as the hash. It was too faint to notice, and it was left out whenever it didn't fit after the short ID.
- **A mark on the graph's dot.** The dot already says the lane's color, a merge and where the worktree is, and in a repository that signs every commit every dot would change.
- **The mark in the author column, beside the name.** The author column is the first to go when the row is short of room, and the signature belongs to the commit more than to the person.
- **Nothing in history, and the line only in the panel.** It's the quietest, but a commit that should have been signed and wasn't would only show once selected.
