# 94. Report an issue from the Help menu, after a dialog says what it opens

Accepted on 2026-11-19.

## Context

Roga is in beta, and the landing page asks people to report what they find on GitHub, but the app itself had no way to get there. Its Help menu held only the item macOS adds by itself, **Roga Help**, which says that help isn't available because Roga has no help book.

A link that goes straight to the browser would be the quickest, but it would take someone out of Roga without warning. They might not expect GitHub, might not have an account there, and might not know that issues are public. Prefilling the issue with versions also sends details about their Mac along with the address, so they should see what those are before the browser opens.

We considered three places for the item:

- **The Help menu.** It's where Mac apps put their links for help and feedback, it works from any window, and it replaces an item that did nothing. This is the one we chose.
- **Settings.** Settings has no About page, and a feedback row among General's settings would be out of place.
- **The dialog for a git failure that an agent couldn't fix.** That's the moment someone is most likely to want to report something, but an issue made there would naturally include the failing command and what git said, which can carry a repository's names and paths. It needs its own decision about what to leave out.

## Decision

**Report an Issue… replaces Roga Help in the Help menu.** It shows a dialog on the focused window. With no window in front, a new window opens and shows it, the way Settings… does. The dialog is on the window rather than inside the workspace, so it also shows during setup, where someone without a git that works may want to report it.

**The dialog says what will happen before anything leaves Roga.** It's titled "Report an issue on GitHub", and it says that a new issue for `tmarkovski/roga` opens in the browser, that nothing is sent until it's submitted there, and that submitting needs a GitHub account. A gray card lists the versions that will be filled in, and a note says that issues are public, so private code and repository names should be left out. **Open GitHub** is the ink button, and Return presses it. Cancel, Escape and the × close the dialog without opening anything.

**The issue starts with three versions and nothing else.** These are Roga's version and build, macOS's version and build, and the version of the git Roga runs, or "None found" when Roga found no git it can use. Above them is a comment, which GitHub hides once the issue is submitted, asking what happened and what was expected. No repository names, paths, remotes or logs are included.

**There's no terminal block.** Decision 29's block shows the commands a dialog will run, and opening a page in the browser isn't one of them.

## Consequences

- The Help menu has a working item, and macOS still adds its menu search field above it.
- The address is in `IssueReport`, and it changes there if the repository moves.
- The issue's body is a query parameter, so it stays short to keep the address well under the length that browsers and GitHub accept.
- An issue form in `.github/ISSUE_TEMPLATE` could later give the issue named fields. The dialog's address would then name the form and fill its fields rather than the body.
- Reporting from a dialog for a git failure is left for a later decision, about what such an issue may include.
