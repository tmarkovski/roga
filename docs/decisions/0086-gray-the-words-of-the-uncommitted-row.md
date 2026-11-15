# 86. Gray the words of the uncommitted row

Accepted on 2026-11-15. This changes how [decision 15](0015-uncommitted-changes-as-a-row-in-history.md)'s row for uncommitted changes looks, and nothing about what it does.

## Context

The row for uncommitted changes, as in **2 uncommitted files**, was in the same black as a commit's subject. Only its hollow dot said it wasn't a commit yet.

History already draws something lighter when it isn't on the branch yet: a commit that a pull would bring in is faded, text and dot alike.

## Decision

**The row's words are in the gray of a commit's author and date,** in the regular weight. Its hollow dot stays as it is.

A worktree with conflicts keeps its red, bold words, as in **Merging · 2 conflicts**, because those need doing before anything else.

## Consequences

- Lighter means "not on the branch yet" both for commits a pull would bring and for changes that haven't been committed.
- The row isn't faded, which would dim its dot too and make it look like a commit from the remote.
- The row still comes first, and the sidebar's orange count still says which worktrees have uncommitted files, so graying it doesn't hide them.
