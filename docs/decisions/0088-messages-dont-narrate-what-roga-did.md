# 88. Messages don't narrate what Roga did

Accepted on 2026-11-15.

## Context

Roga's messages named Roga as whoever did or failed to do something, often twice in one sentence. The Agents page said "Roga couldn't tell whether it's installed: codex didn't finish within 15 seconds, so Roga stopped it." Errors read the same way: "Roga couldn't open … as a repository", "git status printed a record Roga can't read", "Something else has moved HEAD since Roga counted what this would lose, so Roga left it there." Setup put "Roga will use Git 2.54.0" over "Roga runs the Git on your Mac…".

macOS alerts traditionally name the app, as in "Safari can't open the page", because an alert can come up while the app is in the background. Roga's messages show inside its own window, beside what they're about, so the name adds nothing there. Repeated, it reads like a narrator talking about itself.

## Decision

**A message says what happened, or what's wrong, without the app as its subject.** "Couldn't check whether it's installed: codex timed out after 15 seconds." "Couldn't open … as a repository." "git status printed an unexpected record." "Something else moved HEAD in the meantime, so it was left alone." "Sets pull.rebase in its git config, so you won't be asked again."

**Roga is named only where it tells Roga apart from something else:**

- another copy of Roga
- Roga's hooks, plugin or Application Support folder, as against the agent's own
- restarting, quitting or opening Roga
- the "Roga: before …" message on a stash it makes, which shows wherever git lists stashes
- the window's title, the wordmark and "Replayed in Roga"

**Setup names Roga at most once on a screen,** where it says what Roga needs or does: "Roga needs Git 2.44 or newer", or "Roga runs the Git on your Mac, with your own configuration…". The heading above that sentence is now "Git 2.54.0 is ready".

**The hooks' plugin keeps its words,** although its description, which Claude Code shows, names Roga twice. Codex trusts a plugin's hooks by a hash of its files, so new words there would ask everyone to trust Roga's hooks again, and the files would need checking with `claude plugin validate` again. It can change the next time the plugin has to.

## Consequences

- Messages are shorter, and they start with what matters.
- Some sentences become passive, as in "was stopped" or "is required", where the only other subject would be Roga. That's how interfaces usually put it.
- A program that runs past its time limit now "timed out after 15 seconds", rather than "didn't finish within 15 seconds, so Roga stopped it".
- New messages follow the same rule. A sentence where "Roga" could be dropped, or replaced with "it", shouldn't name it.
- The first-run boards still have the old wording. The [first-run README](../design/first-run/README.md) lists where the app now differs from them.
