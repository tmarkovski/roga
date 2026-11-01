# 8. Require git 2.44 or later

Accepted on 2026-11-01.

## Context

Decision 3 says yaga uses the user's git and refuses to run when it's older than a minimum version, and it left that minimum to be set once we knew which features yaga needs. The [roadmap](../../ROADMAP.md) and the prototypes point to these features. The versions come from git's release notes and history:

| git version | Released | Feature | What yaga uses it for |
| --- | --- | --- | --- |
| 2.15 | October 2017 | `--no-optional-locks` | Running status in the background without holding the index lock |
| 2.36 | April 2022 | `git worktree list -z` | Listing worktrees whose paths contain unusual characters |
| 2.36 | April 2022 | The built-in filesystem monitor on macOS | Fast status in large repositories |
| 2.36 | April 2022 | `git cat-file --batch-command` | A long-running process for reading commits |
| 2.38 | October 2022 | `git merge-tree --write-tree`, `git rebase --update-refs` | Previewing merges and history edits without touching the working tree |
| 2.44 | February 2024 | `git replay` | Rewriting branches without a working tree |

git 2.36 would be enough for release 1. git 2.38 would also cover the previews that history editing needs. git 2.44 adds `git replay`.

## Decision

yaga requires git 2.44.0 or later.

## Consequences

- yaga can use every feature in the table without checking the version first.
- Anyone whose only git is older than 2.44 has to upgrade, for example with Homebrew. Apple's git on the Mac yaga is developed on is 2.54.0. Before release 1, we should check which version the Command Line Tools install on macOS 26, because some people rely only on Apple's git.
- `git replay` is still marked experimental, and its options have changed since 2.44. Having a version that includes it doesn't mean yaga can rely on it working the same everywhere. If yaga uses it, it needs a fallback.
- CI runs against git 2.44 and against the newest release.
