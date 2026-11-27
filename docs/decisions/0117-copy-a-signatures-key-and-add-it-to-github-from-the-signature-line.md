# 117. Copy a signature's key, and add it to GitHub, from the Signature line

Accepted on 2026-11-27. This adds a chevron after the words on the commit panel's Signature line from [decision 104](0104-mark-signed-commits-and-check-only-the-selected-one.md), which opens a menu of what can be done with the key that made the signature. Its Add to GitHub… shows the same rows for GitHub and GitLab that [decision 108](0108-make-a-signing-key-and-say-which-signing-programs-are-here.md) shows once New SSH Key… has made a key.

## Context

A commit that git says is good can still show as Unverified on GitHub. GitHub verifies an SSH signature only when the key is on the committer's account as a signing key, which is a separate entry from the same key as an authentication key, and it verifies an OpenPGP signature only when the account has the key as a GPG key. In both cases the account also needs the commit's email. Someone who set signing up before Roga, or on another Mac, has no way in Roga to get at the key's public half. Decision 108 offers it only for a key Roga has just made, and the Signature line showed only the key's fingerprint or ID as text.

An SSH signature carries its public key, which decision 107 already reads to offer Trust This Key…, so Roga can copy it for any SSH-signed commit without running anything. An OpenPGP signature only names its key, so its public half has to come from `gpg --armor --export`, which prints nothing when the keyring doesn't have the key. Roga doesn't read X.509 certificates.

## Decision

**A chevron follows the Signature line's words** and opens one of Roga's own menus, on the press, as [decision 111](0111-open-popovers-on-the-press-as-menus-do.md) asks. It's gray and as small as the chevron in the branch control, and it's there from the start for every signed commit, so that nothing on the line moves when the key has been read or git has answered. The words keep their own tooltip and can still be selected as text. The menu is in sentence case, as [decision 66](0066-sentence-case-branch-icons-and-the-value-on-a-row.md) has the window's menus:

- **Copy public key** copies the key as GitHub and GitLab take it when it's pasted: an SSH key's line, as in `ssh-ed25519 AAAA…`, read from the signature, or an OpenPGP key's armored export from gpg. For OpenPGP it's disabled once git has said that this Mac doesn't have the key, or that it couldn't run gpg. When gpg can't export the key anyway, the Mac's alert sounds.
- **Copy fingerprint** for SSH, or **Copy key ID** for OpenPGP and X.509, copies what the key's line shows.
- **Add to GitHub…**, after a line, names the hosts of the repository's remotes, as in Add to GitHub or GitLab…, which Roga reads from `git config` once while the line shows. It isn't there when no remote is on GitHub or GitLab, for X.509, or for a bad signature or one made with a revoked key, and it's disabled when Copy public key is.

**Add to GitHub… opens a popover from the chevron** titled Add this key, with the key's fingerprint or ID under the title. It says whether the key is one of this Mac's, as the Key field lists them ([decision 106](0106-offer-the-signing-keys-this-mac-has.md)), naming its file, as in `It's ~/.ssh/id_ed25519.pub, one of this Mac's keys.`, and that the host also needs the committer's email on the same account. A key that isn't this Mac's can still be added, since it may be the person's own key from another Mac, but the popover says in amber to add it only if it's yours. Under that are decision 108's rows, which look up gh and its accounts when the popover opens: Add to GitHub when gh may add keys, the `gh auth refresh` command when it's signed in without the scope, and otherwise Open GitHub or Open GitLab, which copies the key and opens the host's page for adding it. Copy Public Key and Done end it, with the command block under them.

**gh takes a key that's in no file on standard input.** A key from one of this Mac's `.pub` files goes in by its path, as a new key does, and keeps its comment. A key read from a signature, or one that's only in an agent, goes in as `gh ssh-key add - --type signing`, with the command block saying that Add to GitHub pipes in the public key.

## Consequences

- Someone whose commits show as Unverified on GitHub can copy the key that signed them, or add it as a signing key, from any of those commits.
- The popover after New SSH Key… and the one from the Signature line share their rows, `KeyHostsContent`, so they say the same thing about each host.
- Selecting a signed commit runs `git config` once more for the remotes, and only the first time the line shows. Opening Add this key also runs `ssh-add -L` or `gpg --list-secret-keys`, to say whether the key is this Mac's, and `gh auth status`.
- The chevron takes about 20 points from the line's words, so at the panel's narrowest the longest of them, such as `Signed with a key not on this Mac`, are cut short sooner, with all of them still in the tooltip.
- Copying from the menu says nothing on screen, as Copy does elsewhere in Roga's menus.

## Alternatives considered

- **A ⋯ at the end of the line,** as rows have. It's further from the words it acts on, and a chevron after a status reads as that status's menu.
- **Making the words themselves the menu's button,** as the branch control is. It's a larger target, but the words could no longer be selected, and the line would shade under the pointer where the Author line beside it doesn't.
- **Copy Public Key as a button after the key,** as Trust This Key… is. Trust This Key… already ends that line for an SSH key git couldn't vouch for, and a second button there wouldn't fit beside it.
- **Offering Add to GitHub… only for this Mac's keys,** as Trust This Key… does. Signing on one Mac and pushing from another is common, and the popover's warning says what's at stake, whereas trusting a key is about whom to believe.
- **Looking up gh and this Mac's keys before the menu opens,** to name the hosts gh is signed in to and to leave out keys that aren't this Mac's. That would run `gh auth status`, which asks GitHub over the network, every time a signed commit is selected.
