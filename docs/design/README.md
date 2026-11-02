# Design exploration

This directory keeps design explorations and their editable assets in version control.

## Initial branding — November 2, 2026

Two names are being explored for the app:

| Name | Expansion |
| --- | --- |
| Yaga | Yet Another Git App |
| Roga | Rather Opinionated Git App |

Both options use the same house on chicken legs. The house leans into a walking stride, with a compact pointed roof and rounded feet. The mascot originated with the Yaga name and its association with a witch's walking house. Roga keeps the mascot and changes only the wordmark. These are initial options; a final name and brand have not been chosen.

| Yaga | Roga |
| --- | --- |
| ![Yaga logo](branding/yaga-logo.svg) | ![Roga logo](branding/roga-logo.svg) |

### SVG assets

| Asset | Yaga | Roga |
| --- | --- | --- |
| Full logo | [Color](branding/yaga-logo.svg) | [Color](branding/roga-logo.svg) |
| Full logo in one color | [Monochrome](branding/yaga-logo-monochrome.svg) | [Monochrome](branding/roga-logo-monochrome.svg) |
| Wordmark only | [Yaga](branding/yaga-wordmark.svg) | [Roga](branding/roga-wordmark.svg) |

The standalone house is shared by both names: [color](branding/yaga-mark.svg) and [monochrome](branding/yaga-mark-monochrome.svg). Its filenames retain the Yaga name from the original exploration.

All SVGs use editable paths and transparent backgrounds. Lettering is outlined and requires no fonts. The window panes and letter counters are transparent cutouts. The Roga version retains the original house path, size and placement, reuses the Yaga **g** and **a** outlines, and adds matching **r** and **o** shapes.

The current colors are orange `#D54802` and dark ink `#16150E`. Monochrome files use `currentColor`, which defaults to black. Set CSS `color` when embedding them inline, or change the fill in the file when using them through an image element.

The SVGs in `branding/` are the saved designs for this exploration. Earlier generated concept boards and working scripts remain in the ignored `output/` directory and are not required to use these assets.
