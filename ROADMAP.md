# Roadmap

This roadmap splits Roga's first releases into phases. Each release should be something people can use every day, and each one builds on the one before it. It describes the order of the work, not dates. The reasons behind specific choices are recorded in [docs/decisions](docs/decisions/README.md).

## Before release 1

So far we have written the [vision](VISION.md) and the [architecture](ARCHITECTURE.md), sketched the [main window](docs/main-window.md), recorded decisions 1 to 13, and built prototypes for:

- [Git access, drawing the history, and the diff view](prototypes/git-access/RESULTS.md)
- [native window tabs](prototypes/window-tabs/README.md), which we decided against
- [the main window](prototypes/main-window/README.md) with Roga's own tabs, which a sidebar later replaced (decision 13)

The project is set up, so the next step is release 1. It has:

- a thin Xcode project in the JSON format and the RogaKit package (decision 11), with the modules that the architecture lists
- Swift 6 language mode with strict concurrency checking
- CI that runs the tests against both the oldest supported git (2.44) and the newest release, and builds the app
- a release workflow that signs and notarizes the app and publishes the Sparkle appcast, so updates work from the first public build

Some of the setup comes later, when there's something for it to work on:

- The benchmark job in CI comes with the first benchmark, in the history work.
- The first release needs a Developer ID certificate, notarization credentials, Sparkle's signing key and a Homebrew tap, which [docs/releasing.md](docs/releasing.md) describes.

## Release 1: a fast viewer for reviewing agents' work

Release 1 is for someone who works in the terminal and keeps Roga open next to it. They use it to read history and to review what they and their agents have changed. It ships as version 0.1.0.

It was planned as a read-only viewer, and it grew while it was built. Several of these changes came forward from release 2, and reverting a commit wasn't planned for any release. Besides keeping the commit-graph file up to date (decision 6), Roga changes the repository in these ways:

- Double-clicking a branch's badge in history or its row in the refs panel checks that branch out with `git switch`. Double-clicking a commit goes to it with `git reset --keep`, `git reset --soft` if the dialog was asked to keep the changes, or `git switch --detach` (decision 37).
- The title row fetches, pulls, pushes and starts new branches (decisions 19, 20 and 45). When uncommitted changes are in the way of a pull or a reset, Roga sets them aside and puts them back afterward (decision 59).
- The panels for uncommitted changes stage files, commit and amend (decision 30), and discard files and hunks, with Undo (decision 39).
- Right-clicking a commit reverts it, either committing the revert or leaving its changes staged (decision 44), and right-clicking a branch or its commit deletes the branch (decision 38).
- Right-clicking a commit or a branch also checks it out, resets to it, merges it, rebases onto it, fast-forwards to it, cherry-picks it, and starts a branch, a worktree or a tag there (decision 65).
- The sidebar makes new worktrees, repairs a worktree whose folder moved, and deletes linked worktrees.

Roga also follows the agents working in each worktree. Settings installs hooks for Claude Code and Codex, and the sidebar then marks the worktrees where an agent is working, waiting or finished, with a line saying what it's doing (decisions 41, 46 and 47). Either agent can write the commit message (decision 41).

The work for reading the repository happened in this order:

1. **History.**
   - The commit graph comes from the commit-graph reader. That includes split chains, commits newer than the file, and the fallbacks to git that decision 5 lists.
   - Roga writes and updates the commit-graph file in the background (decision 6).
   - The commit list is an `NSTableView` (decision 7). It loads the text for visible rows from a long-running `git cat-file` process.
   - The window follows the [main window](docs/main-window.md) wireframe. A sidebar on the left lists repositories grouped by organization (decisions 16 and 53), with their worktrees, a panel on the right shows branches, remotes, tags and stashes, and panels below the history show the selected commit and its diff.
2. **Diffs.** Roga shows unified diffs with changed words highlighted, for a single commit or between any two commits. It shows the list of changed files first and loads each file's patch when it's needed, into a TextKit 1 text view (decision 9). Rename detection is on.
3. **Worktrees and uncommitted changes.** Roga lists every worktree with its branch, its path, and whether it has uncommitted changes, and lets the user switch between them. For any worktree, it shows the staged, unstaged and untracked changes, without changing them.
4. **Branch review.** Roga shows everything a branch changed since it left its base, the way a pull request does. That means the branch's commits and one combined diff against the merge base. The panels under history show it, and two commits or a run of them, as they show one commit (decision 56).
5. **Live refresh.** Roga watches every worktree and the repository with FSEvents. It updates history, branches and changes as the user or their agents write. Background git commands run with `--no-optional-locks`, so Roga never holds the index lock while someone else is running git.
6. **Stashes.** Roga lists the stashes and shows what each one contains. Clicking a stash shows it in the panels under history (decision 56).

### When release 1 is done

Roga ships signed and notarized, with Sparkle updates and a Homebrew cask (decision 1). The steps are in [docs/releasing.md](docs/releasing.md).

### Not in release 1

- anything else that changes the repository, such as staging hunks or lines
- side-by-side diffs and syntax highlighting
- managing submodules or Git LFS
- resolving merge conflicts
- anything specific to GitHub or other hosts

## Release 1.1: finishing the viewer

Release 1 was also going to have file history, search and blame, and to pass the checks below. They didn't hold up the first release, so they come next.

1. **File history.** Roga shows the commits that changed a file or folder, following renames. Where it appears is still open, now that branch review and stashes are in the panels under history (decision 56).
2. **Search** across commit subjects, messages and authors, streamed in the background.
3. **Blame**, showing who last changed each line of a file, and in which commit.
4. **Replaying history.** Roga plays a repository's history as an animation: branches leave the main line, their commits land one by one, and they merge back, ending on the whole range at once. It works in any repository, and saves a video or an image to share. It's built, as [decision 62](docs/decisions/0062-replay-a-repositorys-history.md) describes, and a [prototype](prototypes/history-replay/README.md) tried the motion in a browser first.

### When release 1.1 is done

- Every action has a keyboard shortcut, and the commit list works with VoiceOver. Issues [5](https://github.com/tmarkovski/roga/issues/5) and [12](https://github.com/tmarkovski/roga/issues/12) are open against this.
- CI checks these targets on a repository the size of Linux. They come from what the prototypes measured:
  - When the repository has a commit-graph file, the first screen of history is ready to draw within 100 ms.
  - Scrolling, jumping, selecting a commit, and new commits arriving never take longer than two frames.
  - Status for a worktree finishes within 300 ms. Listing uncommitted files misses this today ([issue 3](https://github.com/tmarkovski/roga/issues/3)).

## Release 2: working with changes

- Stage and unstage by hunk or line. Staging by file, committing and amending came first (decision 30), and discarding after that (decision 39).
- Rename branches and switch branches from the keyboard. Starting a branch from any commit came first (decision 65).
- Ask for a passphrase when git needs one to fetch, pull or push (decision 20).
- Clone a repository into a folder the user chooses, using the user's own credential helpers and SSH setup, and add it to the sidebar. Its action goes under opening a repository at the top of the sidebar.
- Create, apply and drop stashes.
- Decide whether Roga turns on the untracked cache or the filesystem monitor for large repositories.

## Release 3: editing history

- Show interactive rebase as a visual list, where the user can reorder, squash, edit, drop and reword commits.
- Split a commit into several.
- Show the result before applying it, using `git merge-tree --write-tree`, and abort cleanly if a rebase stops partway.
- Consider `git replay` for rewriting branches without touching the working tree. It's still marked experimental, and its options have changed since git 2.44, so Roga would need a fallback.

## Not planned yet

These each need their own decision before they're scheduled:

- side-by-side diffs
- syntax highlighting
- a merge conflict editor
- submodules and Git LFS
- integration with GitHub or other hosts, including listing an organization's repositories to add them
- a view of the work agents are doing, with what's waiting for review, based on the agents' hooks (decision 16)
- a second kind of replay that shows the repository's files and the people changing them, the way Gource does, played by the same player as the replay in decision 62
