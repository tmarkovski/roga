# 107. Trust your own SSH key from the Signature line

Accepted on 2026-11-25. This adds Trust This Key… to the commit panel's Signature line from [decision 104](0104-mark-signed-commits-and-check-only-the-selected-one.md), for an SSH signature made with one of the keys [decision 106](0106-offer-the-signing-keys-this-mac-has.md) lists. It's [issue 119](https://github.com/tmarkovski/roga/issues/119), the part of issue 117 that decision 106 left out.

## Context

git checks an SSH signature only against the file `gpg.ssh.allowedSignersFile` names, which lists whose keys to trust, one line each: the emails a key signs for, options such as `namespaces="git"`, then the key. Without the file, git doesn't check the signature at all, and the Signature line says "Signed with SSH, not checked". With the file, a key it doesn't list gives "Good signature, from a key this Mac doesn't trust". So someone who signs with SSH sees one of those on their own commits until they write that file by hand.

We weighed three places for the offer: the Signature line, the identity popover after choosing a key, and Settings › Git. We chose the Signature line, where the problem shows, and the Commit identity page of the design canvas draws it, in [`docs/design/commit-identity`](../design/commit-identity).

## Decision

**The Signature line offers to trust the key** when git couldn't vouch for an SSH signature, that is, when it says not checked or not trusted, and the key that made it is one of this Mac's SSH keys, as decision 106 lists them. The line's gray detail then names the key, as in `It was signed with ~/.ssh/id_ed25519.pub, one of this Mac's keys.`, and Trust This Key… follows it. A key that isn't this Mac's gets no offer, since vouching for someone else's key is a different question.

**Roga reads the key from the signature itself.** git says which key signed a commit only once it can check it, so Roga reads the commit's `gpgsig` header with `git cat-file commit`, and the public key from the SSH signature in it, which OpenSSH's signature format carries after `SSHSIG` and a version.

**Trust This Key… opens a confirm** that says which key and for which email, and shows what Roga runs and adds, as [decision 29](0029-dialogs-that-say-what-happens-and-show-the-command.md) asks:

- **When nothing names a file yet,** `git config --global gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers`, which is where GitHub's and most guides put it. git reads the `~` in it as the home folder.
- **Then the line it adds,** `email namespaces="git" key`, for the commit's committer email, since the committer is who signs a commit. When `gpg.ssh.allowedSignersFile` already names a file, wherever it's set, the line goes in that file.

Trust Key writes the setting, makes the file and its folder when they're missing, and adds the line, starting a new line if the file doesn't end with one. It never adds a line that the file already has for that key and email, and offers nothing when the file already lists them. The Signature line then checks the commit again, which says Good.

## Consequences

- Someone who signs with SSH sees Good on their own commits after one confirm, and the commits other people sign with keys this Mac doesn't have stay as they were.
- The setting is global, since whose keys to trust is the person's, not the repository's, and every repository's SSH signatures are checked against the same file.
- When the commit panel shows an SSH signature git couldn't vouch for, Roga also runs `git cat-file commit`, `git config` three times and `ssh-add`, after the check that decision 104 already runs.
- A key that signs for several emails gets one line for each email it's trusted for, rather than one line that lists them all.

## Alternatives considered

- **In the identity popover, after choosing an SSH key.** It's where the key is chosen, but trusting it is about checking signatures, and someone whose key was set before Roga would never see the offer.
- **In Settings › Git, as a row with the file and Add My Key.** It's always there, but it's far from the line that says something's missing.
- **`~/.config/git/allowed_signers`.** It's beside git's own config folder, but fewer guides use it, so someone following one would end up with two files.
- **Trusting any key the signature names.** That would vouch for someone else's key without checking who it belongs to, which is what the allowed signers file is for.
- **The key from `git log --format=%GK`.** git prints it only once it can check the signature, so it's empty when the file isn't set, which is the most common case.
