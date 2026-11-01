# Vision

yaga is a fast, native Git client for macOS. It is free and open source, and its home is [yaga.build](https://yaga.build).

## Who it's for

yaga is built first for experienced engineers who already know Git well. They don't need Git explained to them; they want a visual layer that lets them read history, stage precisely, and rewrite commits faster than they could at the command line. Everything in yaga should reward that kind of user: keyboard shortcuts for every action, no confirmation dialogs for routine operations, and no hiding of what Git is actually doing.

People who are newer to Git should still be able to find their way. We get there by making the app clear rather than simplified: actions are labeled with the Git terms they map to, and destructive operations explain what they will change before they run. We don't add separate beginner modes or wizards.

## What makes yaga different

There are already good Git clients for the Mac. yaga earns its place by doing four things better than they do, roughly in this order of priority.

### 1. It stays fast on huge repositories

Opening a repository with hundreds of thousands of commits should feel as quick as opening a small one. The app launches instantly, the commit graph scrolls smoothly at any depth, and status and diffs update without the user waiting. Speed is a feature we measure, not a hope: we keep benchmarks against large public repositories (such as the Linux kernel and Chromium) and treat regressions as bugs.

### 2. It feels like a first-party Mac app

yaga is written in Swift and uses the platform's own frameworks, so it behaves the way Mac users expect. That means standard menus, windows, and text handling; full keyboard navigation; correct behavior with system settings such as appearance, accent color, and accessibility; and no web views standing in for native UI. When the platform has a convention, we follow it. Where a design of our own serves people better, such as yaga's tabs, we draw that part ourselves, but it still behaves the way Mac users expect, with the usual keyboard shortcuts, VoiceOver support, and restored windows.

### 3. It understands how people work with coding agents

More and more code is written by agents running in parallel worktrees, and reviewing that work is becoming a large part of an engineer's day. yaga treats this as a primary workflow rather than an edge case. Worktrees are first-class objects you can see and switch between, branches created by agents are easy to find and compare, and reviewing a large change made by someone else (human or agent) is as comfortable as reviewing a pull request.

### 4. It makes history editing approachable

Interactive rebase, splitting and squashing commits, reordering, and editing old commits should be things people do casually, not things they avoid. yaga makes these operations visual and direct: the user arranges the history they want, sees the result before applying it, and can abort cleanly if a rebase stops partway through.

## Principles

- **Git is the source of truth.** yaga never keeps its own hidden state about the repository that could drift from what `git` sees. A user can switch between yaga and the command line at any moment.
- **The keyboard comes first.** Every action has a shortcut, and the mouse is never required.
- **Speed is part of correctness.** A feature that makes large repositories slow isn't finished.
- **Show what Git is doing.** We name things the way Git names them, and the user can always see the command an action corresponds to.

## Non-goals

These are things yaga deliberately won't try to be, at least for now.

- **Cross-platform.** yaga is a Mac app. Supporting other platforms would mean giving up the native feel that justifies the project.
- **A hosting client.** yaga works with Git itself. It may link out to GitHub or other hosts, but it won't replicate their issue trackers, pull request discussions, or CI dashboards.
- **An editor or IDE.** yaga shows and stages code but doesn't try to replace the user's editor.
- **A Git replacement.** yaga doesn't invent its own branching model or workflow on top of Git.

## Roadmap and decisions

The order of the work, starting with a read-only first release, is in the [roadmap](ROADMAP.md). How the app is put together is described in [ARCHITECTURE.md](ARCHITECTURE.md), and specific decisions about how yaga is built and shipped are recorded in [docs/decisions](docs/decisions/README.md).
