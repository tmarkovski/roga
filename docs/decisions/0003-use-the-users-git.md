# 3. Use the user's git, with a minimum version

Accepted on 2026-11-01.

## Context

yaga runs the `git` binary at least for operations that write to the repository or use the network. How it reads history is still open (see [the vision](../../VISION.md)). We could bundle a known version of git with the app, or use the one the user already has.

Using the user's git means yaga behaves exactly like their terminal does, with the same version, build options, and configuration, and it keeps the app small. That includes the system-level config file that belongs to each git installation. Homebrew's git, for example, turns on the macOS keychain credential helper in `/opt/homebrew/etc/gitconfig`, and a bundled git wouldn't read that file. The cost is that git differs between machines. A Mac often has both Apple's git, from Xcode or the Command Line Tools, and Homebrew's git, at different versions, and either one can be the newer.

## Decision

yaga uses the git installed on the user's machine. It refuses to open repositories when that git is older than a minimum version, and it explains how to upgrade. A setting lets the user point yaga at a specific git binary.

## Consequences

- Finding the user's git takes care. Apps launched from Finder or the Dock get a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) that doesn't include Homebrew's `/opt/homebrew/bin`. yaga has to read the `PATH` from the user's login shell or check well-known locations, and it should show which git it picked and its version.
- `/usr/bin/git` is a stub. When the Command Line Tools aren't installed, running it opens a system dialog asking the user to install them. yaga should detect this case before running git and explain what's going on, instead of setting off the dialog without warning.
- We'll set the minimum version during the prototype of Git access, based on the git features yaga depends on, such as commit-graph files, `git status --porcelain=v2`, and the built-in filesystem monitor.
- CI tests against both the oldest supported git version and the latest release.
- Differences in behavior between git versions become our problem to handle, and bug reports need to include the user's git version.
