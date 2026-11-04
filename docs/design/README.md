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

## Animating the house — November 3, 2026

The mark is one path, so it can't move its legs. For animating, the house is split into a body and two legs ([decision 21](../decisions/0021-draw-the-houses-animations-from-joints.md)).

[`branding/yaga-house-body.svg`](branding/yaga-house-body.svg) is the body: the mark's own outline with the legs cut off, closed across the two places where they join it, in the same coordinates as the mark. `HouseOutline.swift` and the landing page's `site/public/index.html` hold the same path. If the mark's house changes, all three have to be cut again.

The legs aren't artwork. The app draws each one from joints, which are a hip, a knee, a hock, an ankle and three toes, as lines with round ends. `HousePose.mark` places those joints in the stride the mark is drawn in, closely enough that it reads as the logo, but it isn't a trace.

To add an animation, write a `HouseMotion` in `YagaKit/Sources/YagaUI/House/` that returns a pose for any moment, and add a case for it to `HouseAnimation`. It then appears in Settings and in Window > House Animations with the others, and the tests check that it loops without jumping and fits inside the frame. That window shows each animation large, with its joints, at its real sizes, and with its own pause, speed and frame slider.

## Icons — November 3, 2026

The app's icons start as SVGs in [`icons/`](icons/). They're drawn with strokes on a 24-by-24 grid. `icons/lucide/` holds unchanged copies from [Lucide](https://lucide.dev), and each file's first line says which release it came from. `icons/yaga/` holds our own, drawn to match. `Scripts/generate-icons.swift` turns all of them into custom symbols and names them in code ([decision 24](../decisions/0024-icons-as-custom-symbols-from-lucide.md)).

To add an icon:

1. Copy its SVG into `icons/lucide/`, from lucide.dev or from `icons/` in the `lucide-static` npm package, or draw one on the same grid in `icons/yaga/`. In that package, `tags.json` is the way to search, as for `git` or `version control`. Use a name from its `icon-nodes.json`, because other files in `icons/` are aliases of those, which Lucide can rename or remove.
2. Run `Scripts/generate-icons.swift`. It stops with a message if a file has something it doesn't know how to draw.
3. If the icon stands for something in yaga, name it in `YagaKit/Sources/IconUI/Icon.swift`, so that the thing looks the same everywhere.

Lucide's `git-pull-request` icons mean a pull request on a hosting site. `git pull` is `arrow-down-to-dot`, which `Icon.swift` calls `Icon.pull`.
