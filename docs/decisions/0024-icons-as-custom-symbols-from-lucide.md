# 24. Draw the app's icons as custom symbols, from Lucide

Accepted on 2026-11-03.

## Context

SF Symbols doesn't cover what a Git client needs. We found no match for a commit, a merge conflict, a graph, a worktree, a cherry-pick, or an arrow that lands on a node, and its arrows for branching and merging don't look like the commit graph beside them. [Decision 19](0019-pull-and-push-from-the-branch-in-the-title-row.md) drew Pull, Push, Fetch and Branch in code for that reason, and noted that they could become custom symbols later.

[Lucide](https://lucide.dev) is an open-source icon set with about 2,000 icons, drawn with strokes on a 24-point grid and tagged, so `git` and `version control` find what's relevant. Its license is ISC, with MIT for the icons it took from Feather.

We tried these ways to bring its icons into Swift. At 16 points they all draw nearly the same picture, so the choice is about how each one fits the code:

- **Paths in generated Swift.** This is how `HouseOutline` and the old `BranchIcon` work. It takes 35 KB of source for 116 icons, needs no resources, and a stroke can be any width. But every call site has to give a size, and `.font` and `.fontWeight` do nothing.
- **An SVG in a string, read by `NSImage(data:)` and cached.** This takes about 15 lines and no generator. Once cached it redraws as fast as a path, about 19 µs, and it stays sharp when moved between displays. It's still a picture of a fixed size, so it has the same limits as a path, and it's what we'd fall back on without a resource bundle.
- **SVGs in an asset catalog.** It compiles to 251 KB for 116 icons, but a stroke's width is fixed when it's imported, and there are no weights.
- **Lucide's icon font.** It's 980 KB before subsetting, it has no weights, and its icons are private-use characters in text.
- **A Swift package of Lucide's icons.** This adds a dependency beside Sparkle and ships about 2,000 icons to use a few dozen. The one that works with AppKit stores them as assets, and the ones that draw shapes are for SwiftUI only, which can't serve the commit list.
- **Custom symbols.** They behave like the SF Symbols around them, at the cost of a generator and a resource bundle.

## Decision

**The icons are custom symbols.** An icon takes its size, weight and color from the font and style around it, as an SF Symbol does. `Icon.branch.image` works in a label, a button or a menu item, and `Icon.tag.nsImage` takes the same `SymbolConfiguration` the commit list already uses for its badges' colors.

**The SVGs are the source.** They're in `docs/design/icons`, with Lucide's unchanged in `lucide/` and our own in `yaga/`. `Scripts/generate-icons.swift` turns them into the asset catalog and an enum that names them, without any network or third-party tool. A symbol has to be filled outlines, so the script draws each stroke's outline at three weights and three sizes, and the system blends between them. [The design notes](../design/README.md#icons--november-3-2026) say how to add an icon.

**One name for each thing.** `IconUI/Icon.swift` says which icon stands for what in yaga, as in `Icon.worktree` and `Icon.stash`. Code uses those names rather than Lucide's, so a thing looks the same everywhere, and changing what it looks like takes one line.

**The set is bigger than today's needs.** It has 115 icons: what git does, what's around it, such as remotes and worktrees, and general commands. That way the next feature finds an icon from the same family.

**Nothing in the app draws an SF Symbol any more.** One family only looks like one if nothing slips in from another, so a test fails if the app's code asks for an SF Symbol. What macOS draws itself, such as a menu's check marks and the traffic lights, stays as it is.

**The small triangle stays a triangle, but it's hollow now.** Lucide has no filled triangle, and a chevron would have changed what the main window's design describes, so `Icon.disclosure` is its Play icon at the heaviest weight. It keeps a hole in the middle even there, as the outline that it is.

**Decision 19's meanings stay, in new drawings.** Pull's arrow lands on a node and Push's leaves it, which Lucide's `arrow-down-to-dot` and `arrow-up-from-dot` already say. Their nodes are smaller than the ones we drew. Fetch's hollow node has no match in Lucide, so it's our own icon, drawn to match. Branch is Lucide's `git-branch`, with two hollow ends rather than a solid node that forks to a hollow one, and New Branch is `git-branch-plus`.

## Consequences

- `IconUI` is the package's first target with resources. SwiftPM's `Bundle.module` stops the app if it can't find them, so we checked an archive: `YagaKit_IconUI.bundle` ends up in `Contents/Resources`, the signature verifies, and the archived app draws its icons. That archive was signed ad hoc, so a real release through `Scripts/release.sh` is still the last check.
- The compiled catalog is 2.0 MB, or about 18 KB an icon, in an app of 10 MB. Each icon carries three sizes and three weights, because `actool` rejects a template with only one size.
- `cherry`, `inbox` and `turtle` stay at one weight from light to bold, because the outlines of their strokes have different points at different weights, which the system can't blend. The script names any icon like that when it runs.
- Every icon is as wide as the grid, so a column of them lines up to within a point, which is the system's rounding. An icon therefore has margins that SF Symbols' tighter widths don't.
- An icon is decorative, so it says nothing to VoiceOver, where an SF Symbol had a label of its own. A control with only an icon has to name itself with `accessibilityLabel`.
- `SwiftUI`'s `Button` and `Label` take an SF Symbol's name directly, so `IconUI` adds versions of them that take an `Icon`.
- Lucide has no icon for a rebase. `Icon.swift` leaves that out until a feature needs one, when `git-compare-arrows` or `route` are the nearest, or we can draw our own.
- Lucide's `git-pull-request` icons mean a pull request on a hosting site, not `git pull`, which is easy to mix up.
- Lucide's license ships inside the bundle, as `LICENSE-lucide.txt`, and each SVG in `docs/design/icons/lucide` keeps the line that says which release it came from.
