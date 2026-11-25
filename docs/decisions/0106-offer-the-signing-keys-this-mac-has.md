# 106. Offer the signing keys this Mac has

Accepted on 2026-11-25. This turns the Key field of the identity popover and of Settings › Git, from [decision 103](0103-show-who-commits-go-out-as-from-git-config.md), into a field that offers the keys this Mac can sign with. It's [issue 117](https://github.com/tmarkovski/roga/issues/117). [Decision 108](0108-make-a-signing-key-and-say-which-signing-programs-are-here.md) adds New SSH Key… and New OpenPGP Key… at the end of the line under the field. Amended in place on 2026-11-25: the keys open as cards with a radio rather than in a menu, which has room for each key's fingerprint.

## Context

The Key field took the signing key as plain text, so someone turning signing on had to know a key's path or ID. The keys are already on the Mac, and the programs git signs with can list them: `ssh-keygen` and `ssh-add` for SSH, and `gpg` for OpenPGP.

Listing a key that git then can't sign with would be worse than listing nothing, because the next commit, or an agent's, would stop at signing. git signs SSH commits with `ssh-keygen -Y sign`, which signs with the private key beside a `.pub` file, or through the agent that `SSH_AUTH_SOCK` names when it holds the key. Roga gives git its login shell's `PATH` and nothing else from that shell, so that agent is the one macOS starts. 1Password's agent, which `~/.ssh/config` names with `IdentityAgent`, signs only through 1Password's own program, `op-ssh-sign`, set in `gpg.ssh.program`.

## Decision

**The Key field opens the keys from a chevron at its end,** inside the field's right edge, which gets a gray square under the pointer. They open as cards with a radio in a popover, laid out as the popover for a program's copies is ([decision 101](0101-choose-a-programs-copy-in-a-popover-like-the-agents.md)): each card has the key's name with its type at the end, what else tells it apart, and its fingerprint, and the key the field names has the ink edge. Picking one fills the field and closes the popover. In the popover, Save writes it as it writes anything typed, and Settings writes it at once, as it does a field that's left. A path or key ID that isn't listed can still be typed.

**The line under the field says which key it names,** as in `ED25519 · sam@rivera.dev` or `Sam Rivera <sam@rivera.dev> · ED25519 · 4B5A69784F1E2D3C`. A path matches with or without `~`, and an OpenPGP key ID matches the end of a fingerprint, so a key that was set before Roga listed keys is recognized too. When there are no keys to offer, the line says why.

**SSH lists what `ssh-keygen -Y sign` can use:**

- **Each `.pub` file in `~/.ssh`** whose private key is beside it or whose key is in the agent, leaving out certificates. Choosing one writes its path, as `~/.ssh/id_ed25519.pub`, which git reads with `~` as the home folder.
- **The agent's other keys,** from `ssh-add -L`. A key that's only in the agent is written as `key::ssh-ed25519 AAAA… comment`, since git needs either a file or the key itself.
- **1Password's keys,** from `ssh-add -L` with `SSH_AUTH_SOCK` set to the socket `IdentityAgent` names, but only when `gpg.ssh.program` is `op-ssh-sign`. Otherwise git couldn't sign with them, and when that leaves the list empty, the line says so.
- **A security key,** `sk-ssh-ed25519@openssh.com`, says it asks for a touch, which also holds up an agent's commits until someone touches it.
- **When `gpg.ssh.defaultKeyCommand` is set,** the keys start with a card that empties the field, so Save unsets `user.signingkey` and the command picks the key.

**OpenPGP lists what `gpg` can sign with,** from `gpg --list-secret-keys --with-colons`, run with the program `gpg.program` names, or `gpg` from git's `PATH`, Homebrew's folders or GPG Suite's. Keys that have expired, were revoked or are disabled are left out, and so are keys with no part that signs whose secret is here or on a card. A key whose signing key is on a smartcard says so. Choosing one writes its fingerprint.

**X.509 stays a plain field,** since its certificates come from `gpgsm` or `smimesign` and are rarer.

**The keys that name the identity's email come first,** in an SSH key's comment or an OpenPGP key's user IDs, then the rest in the order they were found.

**Roga lists the keys only while the Key field shows,** when the popover opens with signing on, when signing is turned on, or when the format changes, once for each format while the popover or Settings is open. It never lists them with the sidebar's look at a repository, since `gpg` can take a moment while it starts its agent. It keeps nothing about the keys.

## Consequences

- Turning signing on no longer means looking up a key's path or ID, and a key picked from the list is one git can sign with.
- A key that the agent holds only until the Mac restarts is written as the key itself, which keeps working after a restart only if something loads it into the agent again.
- A passphrase-protected key that isn't in the agent is listed, since its private key is beside it, but git can't ask for the passphrase, so a commit would stop at signing until the key is added to the agent.
- `~/.ssh/config` is read only for `IdentityAgent`, without regard to which hosts the line is for.
- Each time the popover opens with signing on, Roga runs `git config` once, then `ssh-add` once or twice for SSH, or `gpg` once for OpenPGP.

## Alternatives considered

- **A menu of keys at the field's end,** which was built first. A menu item has room for two short lines, so the fingerprint didn't fit, and it looked unlike the popover for a program's copies, which picks one of several things the same way.
- **A list of every `.pub` file, with or without its private key.** A public key copied into `~/.ssh` for someone else would look like one to sign with.
- **Always the absolute path.** It's longer, and git reads `~` in `user.signingkey`, which a test signs a commit with.
- **Listing 1Password's keys whenever `IdentityAgent` names its socket.** git would sign through the agent macOS starts, which doesn't have them, so the next commit would stop at signing. Setting `gpg.ssh.program` for someone is a change to how every repository signs, so Roga says what's needed rather than doing it.
- **Offering to add the chosen SSH key to `gpg.ssh.allowedSignersFile`,** so that the commit panel's Signature line from [decision 104](0104-mark-signed-commits-and-check-only-the-selected-one.md) says Good for your own commits. It writes a file and a global setting beyond the identity, so it's left for its own issue, which [decision 107](0107-trust-your-own-ssh-key-from-the-signature-line.md) took up from the Signature line.
- **Listing the keys with the sidebar's look,** so the list would be ready at once. `gpg` can take a second while it starts its agent, and most repositories' popovers are never opened.
