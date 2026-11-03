# 20. Fetch by itself when yaga becomes active

Accepted on 2026-11-03. Fetching comes in release 2, so this isn't built yet.

## Context

[Decision 19](0019-pull-and-push-from-the-branch-in-the-title-row.md) shows how far a branch is from its upstream in the title row, and shows nothing when there's nothing to do. That's only true if something fetched recently. With yaga open beside a terminal and agents pushing to remotes, it often won't have.

We considered three ways to keep the counts fresh:

- **Fetching only when asked.** yaga would change nothing without being told, but Fetch would need a visible button, and a clean title row could be wrong rather than quiet.
- **Fetching on a timer**, as some Git clients do. The counts would stay fresher, but it keeps using the network and the user's credentials for windows nobody is looking at.
- **Fetching when yaga becomes active.** That's when someone looks at the window again, and yaga already looks for changes at that moment.

## Decision

yaga runs a fetch by itself when it becomes active, without asking.

- **What it fetches.** Only the repository on screen, from the remote its branch tracks, or `origin` when it tracks none. A repository with neither isn't fetched. Every worktree of a repository shares its remote branches, so one fetch covers them all.
- **When.** When yaga becomes active, and when a window shows a different repository, because clicking through the sidebar would otherwise show stale counts. It fetches a repository at most once a minute, and doesn't start another fetch while one is running.
- **The command.** `git fetch --no-write-fetch-head --no-auto-maintenance <remote>`. The first flag keeps it from overwriting a `FETCH_HEAD` that the user or an agent is about to use, and the second keeps it from starting a gc in the background. The minimum git from [decision 8](0008-require-git-2-44.md) has both.
- **Quietly.** Nothing shows while it runs, and a failure interrupts nobody, because nobody asked for it. It never prompts for credentials. The branch's menu says `fetching…`, or `couldn't reach origin · fetched 2 h ago`. When it finds something, a count appears or ticks up.
- **A fetch someone asks for is different.** Fetch in the branch's menu shows the walking house and, when it fails, an alert with what git said.
- **Where it shows.** It's listed in the log of git commands yaga ran, because the vision says the user can always see what git is doing.
- **A setting turns this off.** It's on by default, like the commit-graph file in [decision 6](0006-keep-the-commit-graph-up-to-date.md).

## Consequences

- After the commit-graph file, this is the second thing yaga writes without being asked. It only moves remote branches, which are git's own state, so yaga and the command line keep agreeing, and the user's own `git status` gets fresher too.
- ROADMAP.md rules out fetching in release 1, so this waits for release 2. Until then, the counts in the refs panel are only as fresh as whatever else last fetched.
- Commits can appear in history when the user comes back, because a ref that moved loads history again at that moment. On a repository the size of Linux, that takes time, and the commit-graph file needs updating afterward.
- A count can be stale between fetches. Pushing then gets git's rejection, `(fetch first)`, in an alert, and yaga fetches straight after it, which corrects the count.
- It can make an agent's own fetch fail on a ref lock, if both update the same ref at the same moment. That should be rare and it lasts only as long as the update, but agents are the workflow yaga is built around, so it's worth watching for.
- Because a failure is quiet, an expired credential or a locked SSH key means the counts stop updating, and the branch's menu is the only sign.
- `Git.environment` sets `GIT_TERMINAL_PROMPT` to `0` for every git command, which suits this fetch. A fetch, pull or push that someone asks for will need a way to ask for a passphrase, which is still to be designed for release 2.
