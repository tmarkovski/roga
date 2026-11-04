# 34. Name the app Roga, at roga.sh

Accepted on 2026-11-04.

## Context

The app has been called yaga, for Yet Another Git App, with yaga.build as its address. [Decision 22](0022-host-the-landing-page-on-cloudflare-workers.md) put the name Roga on the landing page at roga.sh and left the app, the repository and yaga.build as they were until a name was chosen, so the page and the app have been calling the same thing by two names.

Nothing has been released yet. There are no tags, and the Info.plist has no `SUPublicEDKey`, so no copy of the app looks for updates. A rename won't get any cheaper than this, because once people have the app, a new bundle identifier would leave their saved repositories and settings behind.

## Decision

**The app is Roga, for Rather Opinionated Git App, and its home is [roga.sh](https://roga.sh).** It keeps the house on chicken legs. That house came from the Yaga name, and the [design exploration](../design/README.md) drew Roga with the same house and a new wordmark.

**People read "Roga", and lowercase `roga` is for names in paths and commands.** The docs used to write yaga in lowercase, even at the start of a sentence, while the landing page has written Roga with a capital since decision 22. We followed the page. So the app bundle is `Roga.app` and the app's messages say Roga, while `roga-bench`, `roga-0.2.0.zip` and the like stay lowercase.

**Identifiers follow the domain.** The bundle identifier is `sh.roga.app`, other reverse-DNS names such as queue labels start with `sh.roga`, and Sparkle's feed is `https://roga.sh/appcast.xml`. The Xcode project, the package, its modules and the environment variables that the scripts read were renamed as well, to `Roga.xcodeproj`, `RogaKit`, `RogaUI` and `ROGA_TEAM_ID`, for example.

**Nothing carries data over from the old identifier.** The folder in Application Support and the user defaults both follow the bundle identifier, so a build with the new one starts with an empty sidebar and default settings. Only development builds have ever used the old identifier, so code to move the data would never run for anyone else.

**Decision records keep the old name.** Records aren't rewritten, and each one says what was true when it was written. The exception is a link to a file that moved, which was repointed so that it still opens. Records whose content this decision changes say so at the top.

**The GitHub repository is renamed separately.** Until then, addresses that contain `tmarkovski/yaga` are still correct, so they weren't changed.

## Consequences

- Reading an older record means knowing that yaga is Roga, and its paths and commands use the old names. The [list of decisions](README.md) says so.
- Renaming the repository means changing every `tmarkovski/yaga`, including the download address in `Scripts/release.sh`. Searching for that string finds them all.
- `https://roga.sh/appcast.xml` doesn't exist until the first release puts it in `site/public`. That doesn't matter before then, because the app doesn't start Sparkle until it has `SUPublicEDKey`.
- The Yaga logos and wordmark are gone from `docs/design/branding`. Commit `a285d8d` has them.
- Nothing outside the records mentions yaga.build any more. What happens to that domain isn't decided here.
