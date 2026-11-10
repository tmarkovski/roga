# 73. Choose the code font and its size

Accepted on 2026-11-10. This adds to [decision 9](0009-diff-view-uses-textkit-1.md), whose text view it gives a font that can change, and to [decision 71](0071-choose-monokais-or-xcodes-colors.md), whose colors it gives a preview.

## Context

A diff showed in the system's monospaced font at 12 points, in rows 17 points tall, and nothing could change that. People read code all day in a font and a size they chose for their editor and their terminal, and a git client shows the same code, so most git clients let them choose it there too.

Settings › Appearance also had nothing that showed what a choice would look like. Choosing a color theme changed the window behind the sheet, which the sheet mostly covers.

## Decision

**Settings › Appearance shows a preview under Theme and Colors**: six commits with a four-lane graph and each kind of badge, and under them a commit's files as a tree beside a diff. It's a cutout of the window, drawn by the commit list's own cell, the panels' file rows and the diff's text view, from a history and a patch that are made up. Nothing in it takes a click, and VoiceOver reads it as one image.

**Code font is under the preview, with the family and the size on one row**, and the preview shows both as they change. No line separates the preview from the row above or below it, since its border already does.

- The family's menu offers SF Mono, which is the system's monospaced font and what Roga starts with, and every installed family that has a face whose characters are all one width.
- The size's menu offers 11 to 16, 18 and 20 points. Roga starts with 12.
- Each menu marks what Roga starts with as Default.

The two are on one row, as a font's are in the Mac's own settings. As two rows they ended exactly at the bottom of the sheet, with nothing to show that Lists is further down the page. On one row, the Lists heading is in view.

**The font is for code**: a diff's lines, a conflicted file's lines, and the box a conflict is edited in. Line numbers stay in the system's font, a point smaller than the code. A name that's typed somewhere else, such as a commit's ID, a branch or a command in a dialog, keeps the system's monospaced font at the size its place was drawn for.

**A row is 1.2 times as tall as the font's own line**, rounded to a whole point so that rows start on pixels. SF Mono at 12 points comes to 17, as it was. A font with a taller line of its own, such as JetBrains Mono, gets taller rows at the same size.

**The preview stays the same height in every font**, so that the font's rows under it don't move as sizes are tried. A larger font shows fewer of the sample's lines, as the diff panel would.

## Consequences

- A diff's text is built in a font, away from the main actor, and keeps that font's measures: how tall a row is, how wide a column, and where the text stands in a row. When another font is chosen, each open diff is built again in it and shows at the same line. Changing the font of text that's already laid out would lay a long patch out again on the main actor, which decision 9 keeps off it.
- Where the text stands in a row is asked of TextKit rather than worked out, because TextKit rounds it to a whole point. Line numbers now stand on exactly the text's line. In SF Mono at 12 points that's half a point higher than before.
- A family that's removed from the Mac gives way to SF Mono. The family stays stored, so it comes back if the font does.
- At 11 points a row is 16 points tall, so a hunk's Discard button is 14 points tall there rather than 15.
- There are no commands yet for making the code larger or smaller from the View menu or the keyboard.
