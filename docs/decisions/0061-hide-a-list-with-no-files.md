# 61. Hide a list with no files

Accepted on 2026-11-08. This changes what [decision 55](0055-split-the-panel-for-uncommitted-changes-40-40-and-20.md) says about a list with no files. The 40, 40 and 20 split still holds.

## Context

Decision 55 kept the heading of a list with no files, which said 0 and had no buttons, so that it still said where files would go. It set aside hiding the list because Staged would then come in from nowhere when the first file was staged.

In practice that heading costs a row and offers nothing to act on. Staging the first file already moved the line between the lists, from one heading's height to 40%, so hiding the heading adds only that one row to a move that was happening anyway.

## Decision

**A list with no files isn't shown, heading included, and the other list takes all its room.** It stays in the layout at no height rather than going away, so that it slides with the line between the lists. With nothing staged, the files to stage run down to the message box. With nothing left to stage, Staged starts right under the panel's header, without the line that separates it from a list above.

As in decision 55, this follows the files themselves rather than what a filter matches. A list whose files don't match the filter stays where it is and says so in its own room.

**The heights glide, over 0.22 seconds, when they change all at once.** That's when a list comes or goes, when Amend is turned on or off, and when the message's text arrives from elsewhere: the commit Amend replaces, an agent, or an empty box after a commit. Typing changes the box's height at once, so that it keeps up with the text. Reduce Motion turns the gliding off.

## Consequences

- Staging the first file slides Staged up to 40%, with nothing on screen beforehand to say where it would appear. Unstaging the last one slides it away again.
- The panel no longer says that nothing is staged, except that the Staged list isn't there and the Commit button is off.
- A heading always has files under it, so it always has its buttons and VoiceOver finds its actions.
