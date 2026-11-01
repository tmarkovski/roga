# 6. Keep the commit-graph file up to date automatically

Accepted on 2026-11-01.

## Context

Decision 5 makes yaga read git's commit-graph file to order and lay out history. Many repositories don't have one, or have one that's missing recent commits. git doesn't write the file when it clones. `git gc` writes or updates it by default, but only when it runs. `git fetch` updates it only if the user has turned on `fetch.writeCommitGraph`.

Without the file, ordering the history is slow. On the Linux kernel, `git log --date-order` took 8.8 seconds to fill the first screen. Measured on the same repository, keeping the file current costs:

- 16 seconds to write the file the first time, producing a 96 MB file
- 0.9 seconds for an incremental update with `--split` after a new commit, and 19 ms when nothing has changed
- 2 minutes 9 seconds for a first write that includes changed-path filters. Those filters made no measurable difference to file history in our tests.

We considered three alternatives:

- **Asking the user before writing the file.** That would put a question about an internal cache in front of people who mostly can't judge it.
- **Keeping yaga's own cache outside the repository.** That would mean designing a file format of our own, storing each repository's history twice, and keeping hidden state that the vision rules out.
- **Never writing the file.** That would leave large repositories slow to open.

## Decision

yaga keeps the repository's commit-graph file up to date itself, without asking, by running `git commit-graph write --reachable --split`.

- It writes the file when it opens a repository that has none, and it updates the file when commits that yaga needs are missing from it, for example after a fetch, a commit, or a rebase.
- The work runs in the background at low priority and never blocks the interface.
- It doesn't write changed-path filters.
- It skips repositories where git wouldn't use the file: shallow clones, repositories with grafts or replace refs, and repositories with `core.commitGraph=false`. It also skips repositories whose object folder it can't write to.
- It never changes the user's git configuration. For example, it doesn't set `fetch.writeCommitGraph` or run `git maintenance start`.
- A setting turns this off. It's on by default.

## Consequences

- The first time someone opens a large repository without the file, building it takes noticeable background time, about 16 seconds for a repository the size of Linux. During that time, yaga shows the commit list from `git log` and adds the graph lines once the file exists.
- Because updates use `--split`, yaga's commit-graph reader must read split chains. `git gc` may later merge a chain back into a single file, so the reader has to handle both forms.
- Files in `.git/objects/info/` change while yaga is open, and other tools watching the repository may notice. The writes go through git, which uses lock files, so they're safe while the user runs their own git commands.
- The user's own git commands in the terminal get faster, too, because git reads the same file.
- When yaga can't write the file, because the setting is off or the folder is read-only, large repositories open slowly. yaga should say why rather than just being slow.
