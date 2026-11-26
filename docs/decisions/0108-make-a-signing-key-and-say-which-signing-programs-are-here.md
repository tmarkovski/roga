# 108. Make a signing key, and say which signing programs are here

Accepted on 2026-11-25. This adds New SSH Key… and New OpenPGP Key… to the Key field from [decision 106](0106-offer-the-signing-keys-this-mac-has.md), fades a format in the identity popover's and Settings › Git's picker when its program isn't on this Mac, and adds the signing programs and gh to setup's Look Around from [decision 69](0069-set-roga-up-in-the-whole-window-the-first-time-it-runs.md). It came up while reviewing the work for decisions 105 to 107.

Amended in place on 2026-11-25: the confirm puts the name and email the key is made for, and a new SSH key's file, in a gray card above what it says, rather than inside the sentence and the line under the title. Amended in place on 2026-11-26: the identity popover's Sign commits always shows the formats, beside Off, so it looks for the programs each time it opens, and while commits aren't signed, no format counts as the one git signs with, so git's default, OpenPGP, fades like the others when gpg is missing.

## Context

Decision 106 lists the keys this Mac can sign with, but someone turning signing on may have none yet, and the line under the field could only tell them to run `ssh-keygen` or `gpg --full-generate-key` themselves.

The format picker offered OpenPGP and X.509 whether or not `gpg` and `gpgsm` were installed, and choosing one without its program makes the next commit stop at signing, an agent's included. git's default format is OpenPGP, so turning signing on without choosing a format needs `gpg` too. `ssh-keygen` comes with macOS.

A key that signs is only half of what most people want. GitHub and GitLab show a commit as Verified only once the account has the key's public half. GitHub's own tool, gh, can add one with `gh ssh-key add --type signing` or `gh gpg-key add`, but only when its token has the scope `admin:ssh_signing_key` or `admin:gpg_key`, which `gh auth login` doesn't ask for.

Setup's Look Around is where Roga says what it found on this Mac and what it would use it for, and it said nothing about signing.

## Decision

**The line under the Key field ends with New SSH Key… or New OpenPGP Key…** in the accent, as Use Global and Trust This Key… are, for the format it shows, once the keys have been listed and when the format's program is here. It opens a confirm under the field that says what Roga makes and who could sign with it, and shows what it runs, as [decision 29](0029-dialogs-that-say-what-happens-and-show-the-command.md) asks. A gray card at the top of the confirm, under its title, has the name and email the key is made for, so they can be checked before it's made, with each value in the text's color and its label in gray. An OpenPGP key has Name and Email, and Name is left out when the identity has none. An SSH key has Email, which is the key's comment, and File, since it keeps no name:

- **SSH:** `ssh-keygen -q -t ed25519 -C email -N '' -f ~/.ssh/id_ed25519_signing`, in the first of `id_ed25519_signing`, `id_ed25519_signing_2` and so on that has no file in `~/.ssh`, so it never replaces a key and isn't one `ssh` tries when logging in. The new key then goes in the allowed signers file as Trust This Key… would add it ([decision 107](0107-trust-your-own-ssh-key-from-the-signature-line.md)), for the identity's email, so that git says the commits it signs are good.
- **OpenPGP:** `gpg --batch --yes --passphrase '' --status-fd 1 --quick-generate-key 'Name <email>' ed25519 sign never`, with the program git config names. `--yes` makes it even when another key has the same user ID, and the key signs and doesn't expire.
- **Neither has a passphrase,** since git can't ask for one when Roga or an agent commits, so the commit would stop at signing. The confirm says that anyone who can read the key file, or use the GnuPG keyring, can sign as you.
- **X.509 has no New Key…,** since its certificates come from whoever issues them. When `gpg.ssh.program` is 1Password's `op-ssh-sign`, the confirm says to make the key in 1Password, which signs only with its own keys.
- **The new key goes in the field** as one picked from the list does: the popover's Save writes it, and Settings writes it at once.

**Settings › Agents puts Add Custom Agent… the same way,** in the accent under the list of agents at its right edge, rather than as the list's last row ([decision 89](0089-one-switch-for-agents.md)). Use Global, Trust This Key…, New Key… and Add Custom Agent… share one style for words in the accent that act on what they sit beside.

**Once the key is made, the confirm says where its public half can go,** looked up then rather than in setup, so that a gh signed in or given a scope since counts:

- **The hosts of the repository's remotes:** GitHub, for `github.com` and for a GitHub Enterprise host that gh is signed in to, and GitLab, for `gitlab.com` and hosts named `gitlab.…`. Settings, which has no repository, offers the hosts gh is signed in to.
- **Add to GitHub runs gh** when it's signed in to that host and its token has the scope, which Roga reads from `gh auth status`. An SSH key goes in as a signing key, with `gh ssh-key add ~/.ssh/id_ed25519_signing.pub --type signing --title 'Signing key on Sam's MacBook Pro'`, and an OpenPGP key's `gpg --armor --export` goes into `gh gpg-key add -`.
- **When gh is signed in without the scope,** the command block shows `gh auth refresh -h github.com -s admin:ssh_signing_key`, to run once in Terminal, since it signs in again in the browser. Open GitHub copies the key and opens GitHub's page for adding it.
- **Without gh, and for GitLab,** Open GitHub or Open GitLab copies the key and opens the host's page. Copy Public Key is always there, for any other host.

**The format picker fades a format whose program isn't here.** The popover and Settings › Git look for `ssh-keygen`, `gpg` and `gpgsm`, or the programs `gpg.ssh.program`, `gpg.openpgp.program` or `gpg.program`, and `gpg.x509.program` name, each time they show the format, in the background. They look only for the files, on git's `PATH` and where Homebrew and GPG Suite put them, and run nothing but `git config`. Until they've looked, only the format git signs with now can be chosen. A format whose program is missing stays in its place, faded, so that nothing moves when the answer comes, and its tooltip says what to install, as in `Install GnuPG to sign with OpenPGP`. The format git already signs with is never faded, since that would hide what's so, and the popover warns instead that commits would stop at signing.

**Setup's Look Around has three more rows,** after the agents: SSH, GnuPG and GitHub CLI, each with its version and what Roga would use it for, or Not found. Like an agent that isn't there, a missing one isn't a warning. Setup keeps nothing from them, since the popover and Settings look again each time.

## Consequences

- Turning signing on with no key takes one confirm, and a new SSH key's commits say Good at once.
- Anyone who can read `~/.ssh/id_ed25519_signing`, or use the GnuPG keyring, can sign as the person, as with any key made without a passphrase, and the confirm says so.
- For most people, Add to GitHub needs one `gh auth refresh` first, which Roga can't run for them, because it signs in in the browser.
- Opening the popover also runs `git config --get-regexp ^gpg\.`, and making a key runs `gh auth status`, which asks each host whether gh's token still works.
- Setup's Look Around also runs `ssh -V`, `gpg --version` and `gh --version`.

## Alternatives considered

- **New Key… only as the last item in the list of keys.** It was out of sight until the list opened, and the list doesn't open at all when there are no keys, which is when New Key… matters most.
- **New Key… in the keys' popover as well,** after the cards, which was built at first. It was a second button for the same thing, which the line under the field always shows.
- **Hiding a format whose program isn't here.** The picker would shrink from three segments to two or one when the answer came, moving what's under the pointer, and it wouldn't say why a format is gone.
- **Looking once, in setup, and keeping the answer.** Setup runs once, and never for someone who had repositories before setup existed, so GnuPG installed later wouldn't count until setup ran again.
- **Asking for a passphrase.** An SSH key would need loading into the agent after every restart, and an OpenPGP key would show pinentry, which an agent can't answer, so commits would stop at signing while nobody watched.
- **Uploading with gh whenever it's installed.** gh refuses without the scope, which most logins lack, so Roga checks the scope first and shows the command that adds it.
- **Uploading through GitHub's API with Roga's own sign-in.** Roga has no account, and gh already holds the person's.
- **Offering GitHub only.** GitLab shows signed commits as Verified the same way, and Copy Public Key covers every other host.
- **An OpenPGP key that expires in two years.** An expired key stops commits at signing until someone extends it, often without knowing why.
