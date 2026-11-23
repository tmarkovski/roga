# 97. Start from last launch's PATH, and open the repository a window shows first

Accepted on 2026-11-23. This changes when [decision 3](0003-use-the-users-git.md)'s login shell is read, and the order in which [decision 14](0014-the-sidebar-keeps-every-added-repository.md)'s repositories open.

## Context

Roga's window comes up about 0.4 seconds after launch, and then shows a spinner until it has found git, opened the repository it shows and loaded its history. [Measuring launch](../performance/2026-11-23-launch-time.md) showed that the window wasn't waiting on the main thread, which was idle for most of that time, but on two things in the background:

- **The login shell.** Roga reads `PATH` from an interactive login shell, because apps started from the Dock get a minimal one (decision 3). With the dotfiles on the Mac that was measured, the shell takes about 0.3 seconds on its own, and about half a second while the app is launching. Nothing could look for git until it was done, and nothing could open a repository until git was found.
- **Every repository opening at once.** Once git was found, all of the sidebar's repositories opened together, two `rev-parse`, a `cat-file` and a `worktree list` each, alongside the agents' version checks and the survey of every git. With 16 repositories, the selected one's `worktree list` took 150 to 190 ms instead of the 30 it takes alone, and its history waited for it.

## Decision

**Roga saves the `PATH` the login shell says, and at launch it looks for git in the saved one while the shell starts again.** Windows can open repositories as soon as that git answers `git version`. Since nothing waits for the shell then, it runs at utility priority, so it doesn't take time from the repositories. When it answers:

- If it says the same `PATH`, which is almost always, nothing more happens.
- If it says another, Roga looks for git in that one, saves it, and uses it from then on, as Look Again would. The repositories already opened keep the git and the `PATH` they opened with until Roga quits, the way they keep a git chosen in Settings, so a `PATH` that changed takes over completely at the next launch.
- If it says nothing, such as when it takes longer than five seconds, Roga keeps the saved `PATH` rather than going back to the minimal one it was started with.

If the saved `PATH` has no git Roga can use, the window goes on showing its spinner until the shell answers, rather than saying for a moment that there's no git. The first launch has nothing saved, and waits for the shell as before. So does Look Again, since it's for after something was installed, which the saved `PATH` may not know about.

**The repositories that windows show open before the rest.** That's the one the window that connects shows, and the one selected last in any window. The others start opening once those have, or half a second after they started if they're slow, as one on a network volume can be, so a repository that doesn't answer doesn't hold the sidebar back.

## Consequences

- History shows about 0.4 seconds sooner at launch. On the Mac that was measured, with 16 repositories listed, it went from about 950 ms after the process started to about 550, with a small repository or Linux selected. The [performance record](../performance/2026-11-23-launch-time.md) has the numbers.
- A `PATH` changed since the last launch, such as by installing Homebrew, is used for git from the moment the shell answers, but the repositories already open go on with the old one until Roga quits. Before this decision, the window waited for the new one.
- A `PATH` that's different each time the shell starts, as some version managers make it with a folder named for each shell, looks for git a second time at every launch. The repositories keep the first git, as above, so this costs a `git version` and nothing more.
- A second window restored with another repository doesn't get a head start of its own, since the first window to appear connects the list.
- The rest of the sidebar's repositories fill in a moment later than the shown one, rather than all together.
- It doesn't change how soon the window itself comes up. That's AppKit and SwiftUI creating the window and the menu bar, and Roga's own code is a few milliseconds of it.

## Also considered

**Opening the repositories from the app as soon as git is found,** rather than from the window once it has appeared. With the saved `PATH`, git answers about 0.2 seconds before the window's first frame, so this looked like it would save that much. It saved nothing, because AppKit creates the window in a single pass of the main run loop, and nothing on the main actor runs until that pass is over: not the provider taking the git it found, and not the list starting to open repositories. Starting sooner would mean opening the selected repository and loading its history entirely off the main actor, before any model exists to hold them.
