# 109. Keep the Signature line in place, and let checking be turned off

Accepted on 2026-11-25. This changes how the commit panel's Signature line from [decision 104](0104-mark-signed-commits-and-check-only-the-selected-one.md) looks while git checks a signature and after, moves the explanations and Trust This Key… from [decision 107](0107-trust-your-own-ssh-key-from-the-signature-line.md), and adds a setting that turns the check off. It came up while trying decisions 105 to 108 in the app.

## Context

Selecting a signed commit showed a spinner and Checking… on a line of its own. When git answered, a mark and a few words replaced it, with a gray line of one or two lines under them, and for an SSH key that's one of this Mac's, Trust This Key… under that. So each answer pushed the Parent line and the files down, once or twice, a moment after the commit showed.

A check runs gpg, gpgsm or ssh-keygen for one commit. It took about 30 milliseconds on a Mac whose gpg-agent was running, for an OpenPGP signature and an SSH one, and it only runs for a commit that stays selected for 150 milliseconds. A gpg that hangs leaves the line waiting, as people have reported for Sublime Merge's Signature field.

Other Git clients differ. git itself checks nothing unless asked, since `log.showSignature` is off by default. VS Code's Git Graph shows a signature's status only with `git-graph.repository.commits.showSignatureStatus`, which is off by default. GitKraken puts a badge by the hash in its commit panel, Tower shows a status in its history views, and IntelliJ and Sublime Merge show it in the commit's details, each checking when the commit is viewed.

The key that made a signature is in the commit itself. An SSH signature holds the public key, which decision 107 already reads, and an OpenPGP signature names its issuer.

## Decision

**The Signature line has two lines that are there from the start:**

- **The first has a shield and a few words that fit on one line.** Before git has checked, it says `Signed with OpenPGP`, `Signed with SSH` or `Signed with X.509` beside the plain shield, in gray, with no spinner. When git answers, only the mark, the color and the words change, fading from one to the other over a quarter of a second, while showing another commit changes them at once: `Good OpenPGP signature` in green, `Good signature, key not trusted`, `Good signature, expired key` in amber, `Signed with a revoked key` or `Bad signature` in red, `Signed with a key not on this Mac`, or `Signed with SSH, not checked`. A good signature from someone other than the committer says whose, as in `Good signature from Alex Kim`, since the Committer line doesn't.
- **The second is the key, in the code font,** as git's `%GK` names it after checking: an SSH key's `SHA256:` fingerprint, or an OpenPGP key's ID, the last 16 digits of its fingerprint. Roga reads it from the commit's `gpgsig` header with `git cat-file commit`, without running gpg or ssh-keygen, so it shows as soon as the commit does and doesn't change when git answers. An X.509 signature's certificate isn't read, so its line is empty until git names it.
- **Why, and who signed, are in the first line's tooltip,** such as why git couldn't check an SSH signature, or which of this Mac's keys made it.
- **Trust This Key… ends the key's line,** in the accent, so it doesn't add a line when it appears.

**Settings › Git has a Signed commits section with Check signatures when a commit is selected,** stored as `checksSignatures`, which is on unless it's turned off. Turned off, Roga runs nothing for a signed commit beyond reading its key, and the first line ends with Check, which checks that commit.

## Consequences

- Selecting a signed commit no longer moves anything under the Signature line. Only an X.509 signature's key line fills in late, and it keeps its height while empty.
- Each signed commit that's selected runs `git cat-file commit` once more, which takes a few milliseconds and runs no gpg.
- A long first line is cut short with its words in the tooltip, where the line used to wrap. The words were shortened so that each fits at the panel's default width.
- The signer's name and email show only in the tooltip, unless they aren't the committer's.
- With checking turned off, Good, expired and Trust This Key… wait for Check.

## Alternatives considered

- **Off by default, as in Git Graph.** Every signed commit would say only how it's signed, and Good and Trust This Key… would wait for a click, to save a check that costs about 30 milliseconds and runs only for the commit that stays selected.
- **Keeping the gray line with the signer and the key.** gpg names the signer only after checking, so the line would change, and with a long name it wrapped to a second line.
- **Keeping the spinner in place of the shield.** It said something was happening, but it changed the line's look twice for one answer, and a check is usually done before it would be noticed.
- **Checking every row's signature in history.** It's what decision 104 turned down, for the cost of running gpg hundreds of times as history scrolls.
