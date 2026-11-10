# 74. Switch a diff between its hunks and the whole file

Accepted on 2026-11-10. This adds to [decision 9](0009-diff-view-uses-textkit-1.md), whose text view it gives a second layout, and limits where [decision 39](0039-discard-with-undo-and-ask-only-for-many.md) offers to discard a hunk.

## Context

A diff showed a file's hunks, which is each change with three lines around it under a header such as `@@ -957,7 +957,6 @@ key_ref_t keyring_search(key_ref_t keyring,`. The header's numbers say where the hunk is in the old file and the new one, and the text after them is git's guess at the function the hunk is in. Three lines are often too few to understand a change, and there was no way to see more of the file without opening it somewhere else. Other git clients, GitKraken among them, offer a second view of the same diff that shows the whole file with its changes in place.

## Decision

**A diff has two layouts, Hunk view and Inline view.** Hunk view is what Roga showed before. Inline view shows every line of the file, with the removed and added lines where they are in it, and no hunk headers.

**A button in the diff panel's header switches between them**, before the one for finding text. It looks pressed while the whole file shows, as the button for a tree of files does while they're in one. View > Diff View has both, as Hunks and Inline. The choice is one setting for the app, like the file layout, so it stays from one file, worktree and launch to the next.

**Switching stays at the same line of the file.** The first line of the file in view stays as far from the top of the view as it was. Going back to hunks from a line that no hunk has, the hunk that comes next starts at the top. So does a hunk whose first line was at the top, so that its header isn't left just out of view.

**A file selected in Inline view starts three lines above its first change**, rather than at line 1. The top of a long file can be a long way from a change, and nothing else in the panel says where the changes are. Three lines is what git puts above a hunk's first change, so the change is about where it would be in Hunk view. Hunks still start at the top.

**The whole file comes from git as one hunk.** The commands that print a patch get `-U67108864`, which asks for more lines around each change than a patch Roga reads can have, since Roga stops reading at 64 MB and every line takes at least a byte. git has no option that names the whole file. Roga leaves that hunk's header out, because it would only say that the file starts at line 1.

## Consequences

- Hunks can't be discarded in Inline view, because there are none to point at. The Discard button and the menu item are there again in Hunk view.
- A file with conflicts looks the same in both, since [decision 60](0060-resolve-conflicts-in-the-diff-panel.md) already shows the whole file. The button is unavailable while one shows, as it is for a file with no lines to compare.
- A very large file that changed a little shows in Hunk view, and can be over the 64 MB limit in Inline view, where the panel says it's too large. The button still works then, and switching back reads the file's hunks.
- Line numbers, changed words, finding text and the code font work the same in both, because Inline view is the same kind of document with more lines in it. A file over 50,000 lines isn't laid out ahead of time, as with a patch that long.
- A file that became another kind of file shows the old file's lines and then the new one's, with nothing between them.
- Switching to Inline view runs git again, so a long file shows a spinner after 150 ms, as selecting it does.
- There's no keyboard shortcut for switching yet, and nothing for it in Settings.
