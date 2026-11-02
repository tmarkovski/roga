# Roadmap

This roadmap splits yaga's first releases into phases. Each release should be something people can use every day, and each one builds on the one before it. It describes the order of the work, not dates. The reasons behind specific choices are recorded in [docs/decisions](docs/decisions/README.md).

## Before release 1

So far we have written the [vision](VISION.md) and the [architecture](ARCHITECTURE.md), sketched the [main window](docs/main-window.md), recorded decisions 1 to 13, and built prototypes for:

- [Git access, drawing the history, and the diff view](prototypes/git-access/RESULTS.md)
- [native window tabs](prototypes/window-tabs/README.md), which we decided against
- [the main window](prototypes/main-window/README.md) with yaga's own tabs, which a sidebar later replaced (decision 13)

The project is set up, so the next step is release 1. It has:

- a thin Xcode project in the JSON format and the YagaKit package (decision 11), with the modules that the architecture lists
- Swift 6 language mode with strict concurrency checking
- CI that runs the tests against both the oldest supported git (2.44) and the newest release, and builds the app
- a release script that signs and notarizes the app and updates the Sparkle appcast, so updates work from the first public build

Some of the setup comes later, when there's something for it to work on:

- The benchmark job in CI comes with the first benchmark, in the history work.
- The first release needs a Developer ID certificate, notarization credentials and Sparkle's signing key, which [docs/releasing.md](docs/releasing.md) describes. The Homebrew cask follows the first release.

## Release 1: a fast read-only viewer

Release 1 is for someone who works in the terminal and keeps yaga open next to it. They use it to read history and to review what they and their agents have changed.

yaga doesn't change the repository in release 1. The only exception is the commit-graph file, which it keeps up to date (decision 6). Switching worktrees changes what yaga shows. It never runs `git checkout`.

The work happens in this order:

1. **History.**
   - The commit graph comes from the commit-graph reader. That includes split chains, commits newer than the file, and the fallbacks to git that decision 5 lists.
   - yaga writes and updates the commit-graph file in the background (decision 6).
   - The commit list is an `NSTableView` (decision 7). It loads the text for visible rows from a long-running `git cat-file` process.
   - The window follows the [main window](docs/main-window.md) wireframe. A sidebar on the left lists repositories and their worktrees, a panel on the right shows branches, remotes, tags and stashes, and panels below the history show the selected commit and its diff.
2. **Diffs.** yaga shows unified diffs with changed words highlighted, for a single commit or between any two commits. It shows the list of changed files first and loads each file's patch when it's needed, into a TextKit 1 text view (decision 9). Rename detection is on.
3. **Worktrees and uncommitted changes.** yaga lists every worktree with its branch, its path, and whether it has uncommitted changes, and lets the user switch between them. For any worktree, it shows the staged, unstaged and untracked changes, without changing them.
4. **Branch review.** yaga shows everything a branch changed since it left its base, the way a pull request does. That means the branch's commits and one combined diff against the merge base.
5. **Live refresh.** yaga watches every worktree and the repository with FSEvents. It updates history, branches and changes as the user or their agents write. Background git commands run with `--no-optional-locks`, so yaga never holds the index lock while someone else is running git.
6. **File history and stashes.** yaga shows the commits that changed a file or folder, following renames. It also lists the stashes and shows what each one contains.

Release 1 can ship without the next two items. They're built last, and if they aren't ready they follow in release 1.1.

7. **Search** across commit subjects, messages and authors, streamed in the background.
8. **Blame**, showing who last changed each line of a file, and in which commit.

### When release 1 is done

- Every action has a keyboard shortcut, and the commit list works with VoiceOver.
- CI checks these targets on a repository the size of Linux. They come from what the prototypes measured:
  - When the repository has a commit-graph file, the first screen of history is ready to draw within 100 ms.
  - Scrolling, jumping, selecting a commit, and new commits arriving never take longer than two frames.
  - Status for a worktree finishes within 300 ms.
- yaga ships signed and notarized, with Sparkle updates and a Homebrew cask (decision 1).

### Not in release 1

- anything that changes the repository, such as staging, committing, checking out, fetching or pushing
- side-by-side diffs and syntax highlighting
- managing submodules or Git LFS
- resolving merge conflicts
- anything specific to GitHub or other hosts

## Release 2: working with changes

- Stage and unstage by file, hunk or line, and discard changes.
- Commit and amend. The user's git runs their hooks and signs their commits.
- Create, switch, rename and delete branches, and create and remove worktrees.
- Fetch, pull and push, using the user's own credential helpers and SSH setup.
- Clone a repository into a folder the user chooses, with the same credential helpers and SSH setup, and add it to the sidebar. Its action goes under opening a repository at the top of the sidebar.
- Create, apply and drop stashes.
- Decide whether yaga turns on the untracked cache or the filesystem monitor for large repositories.

## Release 3: editing history

- Show interactive rebase as a visual list, where the user can reorder, squash, edit, drop and reword commits.
- Split a commit into several.
- Show the result before applying it, using `git merge-tree --write-tree`, and abort cleanly if a rebase stops partway.
- Consider `git replay` for rewriting branches without touching the working tree. It's still marked experimental, and its options have changed since git 2.44, so yaga would need a fallback.

## Not planned yet

These each need their own decision before they're scheduled:

- side-by-side diffs
- syntax highlighting
- a merge conflict editor
- submodules and Git LFS
- integration with GitHub or other hosts
