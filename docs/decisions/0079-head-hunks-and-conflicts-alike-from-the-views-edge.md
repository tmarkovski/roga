# 79. Head hunks and conflicts alike, from the view's edge

Accepted on 2026-11-15. This changes how [decision 78](0078-stage-hunks-from-a-band-of-two-rows.md) drew a hunk's header and how [decision 60](0060-resolve-conflicts-in-the-diff-panel.md) drew a conflict's band.

## Context

Once a hunk's band had a gap above it and buttons that are only their words, a hunk and a conflict looked like two different things. A hunk's header was git's `@@` line in gray, starting where the code starts, after the line numbers, so it read as one more line of the file. A conflict's band was tinted gray with a line above and below, its label was in the system's type after an icon in the gutter, and its buttons had borders, two of them in each side's color. Conflicts also ran straight on from the lines above them.

Both bands also put their buttons at the very edge of the view. With overlay scrollbars, which most Macs use, the scroller draws over the text rather than taking room from it, so when it showed, it covered the end of Stage Hunk or Undo.

## Decision

**A band's words start at the view's left edge, in bold.** A hunk's header and a conflict's label start 10 points from the edge, over the line numbers, in the bold of the code font, so each reads as the heading of what's under it. A hunk's header is in gray. A conflict's label is red until it's resolved, then gray, after the warning or check icon it already had. A hunk's header is drawn over the gutter and the text rather than in the text, so it stays put as the text scrolls sideways, as the buttons do, and clicks still go through it to the text. While the band's buttons show, the header ends with an ellipsis before them, rather than running under them.

**A conflict's band is drawn as a hunk's is.** It keeps its two rows, with the same gap above them, which sets it apart from the conflict or lines before it, then its label and buttons centered in what's left, over a thin line. It has no tint. While an agent works, the outline around a conflict starts under the gap, where the band does.

**A conflict's buttons are only their words.** They're the size of a hunk's buttons, with no border, filled with the panel's color at rest and with gray while the pointer is on them. Keep main's and Keep theirs keep their side's color, in their words now rather than their borders. Keep Both, Edit…, Show Sides and Undo are in the text's color, so Undo is no longer orange.

**Buttons on a band stop short of an overlay scroller.** When the system's scrollbars are overlay scrollbars and the text can scroll, a band's buttons end 6 points before the scroller, and the band itself still runs under it. A legacy scroller already takes its room from the text, so nothing moves for it.

## Consequences

- With overlay scrollbars, the buttons sit a scroller's width further in on a diff that scrolls than on one that fits, and move when a diff grows past the view's height.
- Hunk and conflict bands never show together, since a conflicted file shows its conflicts rather than a patch, so a hunk's header and a conflict's label needn't line up exactly. The label starts after the icon.
- Without the tint, a conflict stands out by its red label and its sides' colored rows below it.
