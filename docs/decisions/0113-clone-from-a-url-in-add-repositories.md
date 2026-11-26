# 113. Clone from a URL in Add Repositories

Accepted on 2026-11-26. This adds cloning to the Add Repositories popover from [decision 53](0053-organizations-as-groups-in-the-list-and-add-and-settings-at-the-top.md), and replaces the roadmap's line that put it in a row of its own at the top of the sidebar ([issue 121](https://github.com/tmarkovski/roga/issues/121)).

## Context

Roga could only add repositories that were already on this Mac. Getting a new one in meant going to a terminal, running `git clone`, coming back and finding it with Add Repositories or File > Open….

The roadmap said cloning's action would go under opening a repository at the top of the sidebar. That line came before decision 53, which kept the top of the sidebar to two rows, Add Repositories and Settings. A third row would cost every window 32 points for something done once in a while, and it would split adding in two: whether a repository is in `~/git` already or on a server, the person wants it in the sidebar. The popover also already knows where clones live, since it looks in the folders that listed repositories are in ([decision 16](0016-a-rail-of-organizations-in-the-sidebar.md)).

We looked at four ways to offer it inside the popover:

- **The filter field takes a URL too.** It needs no extra click, but a field that says it filters isn't somewhere anyone would think to paste a URL, and the popover would change what it is depending on what was typed.
- **A Clone from URL… button in the footer,** beside Look in Another Folder…, which turns the popover into a form with a back button. It's hidden until someone reads the footer, and three buttons need a wider popover.
- **A sheet of its own,** as Xcode and GitHub Desktop have. It stays open while the person copies a URL in a browser, but it's a second place to add from.
- **A segmented control under the title,** with On This Mac and From a URL. Both ways to add are in view as soon as the popover opens, and it's the usual way on the Mac to switch a panel between two views.

## Decision

**Add Repositories has a segmented control under its title, with On This Mac and From a URL.** On This Mac is the list of clones it had before, with its filter, Look in Another Folder… and Add Selected. From a URL is a form for cloning. The popover remembers which it showed last, along with what the form was given, while the window is open.

**The form has a URL, a Name, a Folder and Clone submodules too.**

- **Name** follows the URL's last part without `.git`, as git would name the folder, until the person types one of their own. Clearing it goes back to the URL's.
- **Folder** is a pop-up of the folders Add Repositories looks in, starting with the one most listed repositories are in, and **Choose…** at its end opens the open panel, which can make a new folder. The popover closes while the panel is up and opens again after, as it does for Look in Another Folder….
- **Clone submodules too** is on unless the person turns it off, and adds `--recurse-submodules`. git's `submodule.recurse` setting doesn't apply to `git clone`, so without it a repository with submodules arrives with their folders empty.

**A command block shows exactly what will run** ([decision 29](0029-dialogs-that-say-what-happens-and-show-the-command.md)), as in `git clone --progress --recurse-submodules --end-of-options https://github.com/owner/repo /Users/me/git/repo`, and changes as the form does. `--progress` has git say how far along it is even though it isn't writing to a terminal, and `--end-of-options` keeps a URL that starts with `-` from being read as an option. Until there's a URL, the block says that the command will show there.

**It says what's in the way before Clone is pressed.** If something is already at the folder the clone would make, the form says so in red, and Clone stays disabled. If the sidebar already has a repository with a remote at that URL, however it's written (an SSH and an HTTPS URL for the same repository are the same), it says so and offers Show, which shows that repository and closes the popover. Clone still works then, for someone who wants a second clone.

**Clone closes the popover, and the repository gets its row straight away,** in the group of the owner in its URL ([decision 18](0018-every-remote-counts-toward-a-repositorys-organization.md)). It's faint, as a row that's still loading is, and its second line ([decision 48](0048-a-second-line-under-a-sidebar-row-while-theres-something-to-say.md)) says how far along git is, as in `Cloning · receiving objects` with `42%` at the right, or `Cloning vendor/lib · resolving deltas` once git has moved on to a submodule. The row can't be selected while git runs, and its menu has only **Cancel clone**. Cancelling stops git, which deletes the folder it was making, and the row says `Cancelling clone…` until it has.

**When the clone is done, the row becomes an ordinary row and the window shows it,** unless the person has selected another worktree in the meantime. Only then is it saved in the list, so a clone that's still running when Roga quits isn't listed at the next launch.

**When git refuses, the refusal dialog shows the command and what git said,** without its lines of progress, and the row goes. Nothing can answer a prompt, since `Git` sets `GIT_TERMINAL_PROMPT=0`, so a credential that needs asking for fails and git says why. Asking for one is a separate roadmap item, under [decision 20](0020-fetch-when-yaga-becomes-active.md). The dialog doesn't offer to fix it with an agent ([decision 63](0063-ask-an-agent-to-fix-what-git-refused.md)), since there's no repository for the agent to work in.

**git runs as the person would run it,** with their credential helpers and SSH setup, as Pull and Push do. `Git.run` can now pass on what a command writes to standard error as it arrives, which is how the row reads git's progress.

**File > Clone Repository…, with Shift-Command-O,** opens the popover on From a URL with the URL field focused, showing the sidebar first if it's hidden. The window that has no repositories offers Clone Repository… beside Open Repository….

**It doesn't offer a URL from the clipboard** as the popover opens, as some Git apps do. Pasting is one keystroke, and macOS 26 can ask the person before an app reads the clipboard by itself.

## Consequences

- Cloning takes one popover and no terminal, and the repository lands where it would be listed anyway.
- The top of the sidebar stays at two rows, and adding stays in one place.
- On This Mac needs one more click than before to reach From a URL, and File > Clone Repository… skips it.
- A clone that's running when Roga quits goes on to the end without Roga, and its folder isn't listed. Add Repositories finds it there later.
- Listing an organization's repositories from GitHub or another host, shallow and partial clones, picking a branch, bare clones and mirrors are left out.
