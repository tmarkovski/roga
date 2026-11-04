# 23. Show a branch and its upstream as one badge, and a commit's body after its subject

Accepted on 2026-11-03. The options were drawn on the design canvas, with the rows and the selection from a real screenshot of history. [Decision 35](0035-one-cloud-for-each-remote-on-a-badge.md) changed what happens to another remote's branch of the same name, which now joins the badge with a cloud of its own. The rest of this decision still holds.

## Context

Every ref in history had its own badge, in a system color at 14% over whatever was behind it. Selecting a row muddied the fill, and the text was hard to read even without that: green measured 1.98:1 on white and 1.65:1 on the selection, and the best of the four colors, purple, only 3.42:1 on white. A purple badge next to a purple dot in the graph's second lane also looked meaningful, and it wasn't.

A pushed branch took two badges, such as `main` and `origin/main`, so a commit with three branches had six, and they left little room for the subject. Someone using history to check on agents' work mostly wants to know why a commit was made, which is in its body. They also asked whether a row could say how much a commit changed. Neither was worth adding if it slowed the list down.

## Decision

- A badge's colors are opaque, so it looks the same on a selected row.
- Only where you are is filled. The current branch is solid green with a checkmark, and `HEAD` is the same without one when it isn't on a branch. That sets it apart by its shape rather than by a hue, and it goes with the ring and bold text the commit already has.
- Every other badge is white with a thin edge, or dark gray in dark mode. Local branches have blue text. Remote branches and tags have gray text. Color says how much a ref is yours rather than what kind it is.
- A remote's branch is written as its name and then its remote, as `tm/fix | origin`, rather than as `origin/tm/fix`. It reads the same as the local branch of that name, and it's clearer that it's on a remote. When a local branch catches up with it and they share a badge, the remote gives way to a cloud and the text turns blue. A badge is a label, and the refs panel already lists a remote's branches by name under their remote. Anything in words, such as a menu's heading, an alert, a tooltip or Copy Name, still says `origin/tm/fix`, because that's what git calls it and what you'd type. That matters most in the menu that deletes a branch from a remote, which should name exactly what it deletes.
- A branch and its upstream share a badge, with a cloud after the name, when the branch tracks a remote's branch of the same name and both are on this commit. Otherwise each keeps its own. That's the case when they're on different commits, when the branch tracks nothing, when the names differ, because one badge would hide the name everyone else sees, and for another remote's branch of the same name.
- A shared badge still stands for both refs. Right-clicking the row lists both, double-clicking checks out the local one, and its tooltip and VoiceOver name both.
- The rest of a commit's message follows its subject in gray, on one line, without trailers such as `Signed-off-by`, in whatever room the subject leaves.
- Rows don't say how many files or lines a commit changed.

## Consequences

- The upstream comes from one more field in the `for-each-ref` that already runs, and git reads it from its config rather than from any object. On a generated repository with 25,500 refs, 500 of them branches with upstreams, the command went from about 34 ms to about 37 ms, away from the main thread.
- The body costs no more git work, because the row already reads the whole message. Going through the messages of 65 of Linux's commits takes about 4 ms, and that now happens away from the main thread, along with the subjects that used to be read on it. A row with a body takes about 0.3 ms to draw instead of 0.1 ms on an M1 Max, when it scrolls into view. A body is cut at 200 characters, and at what can fit when it's drawn, because laying out text takes time in proportion to its length.
- Symbols were made again every time a badge was laid out or drawn. They're kept now, which more than pays for the cloud: a row with two shared badges and a body takes less time to draw than the same branches as four badges without a body, 0.41 ms against 0.48 ms.
- A commit records only its tree and parents, so change counts would have to be worked out for each commit. A single long-running `git diff-tree --stdin --name-only -M` could count files for 65 rows in about 6 to 11 ms, with a worst case of 147 ms. Adding `--numstat` for line counts takes 39 to 131 ms and up to 544 ms, because git reads both versions of every changed file. Those were timed on clones with 2,052 and 4,184 commits, because the Linux test clone has no trees or files. File counts are the place to start if a row needs this later, in a column of their own so that nothing shifts when they arrive, after timing them on a full clone of Linux. Line counts don't belong in the list.
- A branch that has moved away from its upstream just loses its cloud, and its row doesn't say how far. The title row and the refs panel already do.
- The label colors are fixed values rather than system colors, chosen for contrast, so they don't follow the accent color or the Increase Contrast setting.
- A remote whose name has a slash in it keeps two badges, and its badge is split at the first slash, because a ref's name alone can't tell it from a branch whose name has one. Its tooltip has the whole name.
