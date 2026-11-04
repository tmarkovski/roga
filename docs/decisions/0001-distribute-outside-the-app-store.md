# 1. Distribute outside the Mac App Store

Accepted on 2026-11-01. [Decision 34](0034-name-the-app-roga.md) renamed the app and moved its address to roga.sh. The rest of this decision still holds.

## Context

Apps in the Mac App Store must run in the App Sandbox. A sandboxed app can open only the folders the user picks, and it has to store security-scoped bookmarks to reopen them later. Processes the app launches inherit the same sandbox, so a `git` process started by yaga couldn't read the user's `~/.gitconfig`, SSH keys, SSH agent socket, or credential helpers, and repository hooks would run under the same restrictions. Working around this would break the principle that Git behaves in yaga exactly as it does at the command line.

## Decision

yaga ships as an app signed with a Developer ID and notarized by Apple. People download it from [yaga.build](https://yaga.build) or install it with a Homebrew cask. It doesn't use the App Sandbox. Updates are delivered with [Sparkle](https://sparkle-project.org).

## Consequences

- The release pipeline needs an Apple Developer account, a Developer ID signing certificate, and a notarization step.
- We host a Sparkle update feed and sign each update with the project's update key, which has to be kept safe.
- The Homebrew cask needs a new version for each release. This should be automated as part of the release.
- Without the sandbox, yaga can read any file the user can. It should only touch repositories the user has opened and the Git configuration that `git` itself reads.
