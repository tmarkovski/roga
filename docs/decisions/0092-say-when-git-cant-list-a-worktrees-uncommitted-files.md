# 92. Say when git can't list a worktree's uncommitted files

Accepted on 2026-11-18. This adds to [decision 15](0015-uncommitted-changes-as-a-row-in-history.md), whose row for uncommitted changes now also stands for a worktree git can't list, and to [decision 28](0028-show-a-worktree-thats-stuck-partway.md), whose triangle beside the sidebar's count now also marks one.

## Context

Roga runs `git status` for the row in history and for each worktree's count in the sidebar. When git failed, both took that as no files: the row went away and so did the count, which is exactly how a clean worktree looks, and nothing said why. git fails here for several reasons:

- The list of files is longer than the 64 MB Roga reads, as when a folder of generated files isn't ignored. The worktree with the most changes then looked like it had none.
- The index is damaged.
- A partial clone has nothing checked out, and status is kept from downloading what it's missing.

The changes panel already showed git's message when its own reading failed, but the panel only opens from the row, which wasn't there. The dialog for resetting took its count from the same place, so in a worktree git couldn't list, Hard had an ordinary button and said nothing about uncommitted files, although `git reset --hard` would throw away every change to a tracked file.

## Decision

**The row for uncommitted changes stays while git can't list them, and says "Can't list uncommitted files"** in the red, bold words of a worktree with conflicts, since nothing about what's uncommitted can be trusted until it's fixed. A merge or rebase that stopped partway still comes first in the row. Selecting the row shows git's message in the panel, as for any other failure there.

**The sidebar puts an orange triangle where the count would be,** with no number. Its tooltip is "Can't list uncommitted files:" followed by git's message, and VoiceOver reads "can't list uncommitted files" with the row's other facts.

- The row for a collapsed repository's hidden worktrees adds the triangle before its count, and its tooltip says how many of them git can't list.
- The worktree menu in the title row has the same triangle, and git's message under the folder in the row's tooltip, since a menu's count has no tooltip of its own.

**Hard is in red when git can't list the files,** with the note "The uncommitted files can't be listed, so there may be some."

**A bare repository has no files, so it still has no row or mark.** Roga doesn't run status in one.

## Consequences

- A partial clone with nothing checked out, such as the clone of Linux for measuring history, now has the row and the triangle where it had nothing, with git's "bad tree object" message. That's accurate: status can't run there without downloading.
- A worktree with too many changes to read is the one this helps most, since it used to look like the cleanest one.
- The count of a collapsed repository's hidden worktrees, and sorting the sidebar by changes, leave out a worktree git can't list.
- A failure that goes away by itself shows until the next look, which comes with the next change on disk, when a window shows the worktree again, or on View > Reload.
