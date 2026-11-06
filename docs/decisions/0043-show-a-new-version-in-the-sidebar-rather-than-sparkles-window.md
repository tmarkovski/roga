# 43. Show a new version in the sidebar, rather than in Sparkle's window

Accepted on 2026-11-06.

## Context

Roga updates through Sparkle's standard updater ([decision 1](0001-distribute-outside-the-app-store.md)). When its daily check finds a new version, Sparkle opens its own window, which lands on top of whatever someone is doing. It also asks, on Roga's second launch, whether to check automatically at all, and Settings had nowhere to change that answer later.

Roga's code is in RogaUI, which doesn't link Sparkle. Only the app target does, so until now the one thing in Roga that reached Sparkle was the Check for Updates… command, which the app target builds itself.

## Decision

**A new version is a notice in every window, in the brand's orange.** It's an arrow in a circle on the rail, just above the gear, with a tooltip such as Update to 1.4. The rail is narrow, so it has no words. While the rail is hidden, the gear is hidden with it, so the notice moves to a row at the bottom of the sidebar's list that reads Update to 1.4. It's `Palette.action`, the orange for what a click would run, which is why [decision 36](0036-a-solid-ink-tile-for-whats-selected-on-the-rail.md) kept that orange off the rail's selection.

**Sparkle's window opens only when someone asks for it.** Roga turns on Sparkle's gentle reminders and tells it never to show a scheduled update itself. Clicking the notice calls `checkForUpdates()`, which opens Sparkle's window for that version, with its release notes and Install Update. A check someone starts from the app menu still opens the window straight away, since they asked.

**The notice stays until the version installs or is skipped.** Remind Me Later keeps it, so that it can be found again, and Skip This Version takes it away. A check that finds nothing newer takes it away too.

**A downloaded version reads Restart to Update.** When Sparkle downloads updates by itself, it hands Roga a block that installs the download and relaunches, and a click on the notice runs it. Otherwise the download installs when Roga quits. Roga takes that block, which stops Sparkle's later checks until it's used or Roga quits.

**Sparkle no longer asks whether to check.** `SUEnableAutomaticChecks` is on in the Info.plist, so checking is on from the first launch, as the design canvas draws it. Settings' new General page has Check for updates automatically to turn it off, and Download updates automatically, which is off until someone turns it on there or with the checkbox in Sparkle's window. Both switches are Sparkle's own settings, so they stay in step with that checkbox.

**RogaUI gets Sparkle's state through `Updates`.** It's an observable object in RogaUI with the version waiting and the two settings, and `UpdaterControls` is what it asks of Sparkle. The app target's `SparkleUpdates` is Sparkle's delegate, keeps `Updates` current and does what it asks. Every window and Settings read `Updates` from the environment.

## Consequences

- Sparkle still finds, downloads, checks the signature of and installs every update, and still draws the window with the release notes. Roga only decides when that window opens.
- Someone who never looks at the sidebar's bottom corner can miss a new version for a while. That's the trade for not interrupting, and Restart to Update still installs a downloaded one when Roga quits.
- A build without `SUPublicEDKey`, which is every build until the first release, doesn't start Sparkle, so it never shows the notice, and General says why its switches are off.
- It was tried with a test copy and an appcast served from the same Mac, as [docs/releasing.md](../releasing.md) describes: the notice appeared after the first check, Remind Me Later kept it, Skip This Version removed it, and with downloading on, Restart to Update installed 1.4 over 1.3 and relaunched.
