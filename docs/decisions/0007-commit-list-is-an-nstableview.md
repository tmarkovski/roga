# 7. Build the commit list on NSTableView

Accepted on 2026-11-01.

## Context

The vision says yaga stays fast on huge repositories and feels like a first-party Mac app. We expected SwiftUI to struggle to show a history of a million commits, and the [drawing prototype](../../prototypes/git-access/RESULTS.md#drawing-the-history) tested that with Linux's 1.5 million commits. It compared an AppKit `NSTableView`, a SwiftUI `List`, and a SwiftUI `LazyVStack`.

All three scrolled smoothly, with no frame longer than 18 ms at 60 Hz. The difference was in what happens when something changes:

| With 1.5 million commits | `NSTableView` | SwiftUI `List` | SwiftUI `LazyVStack` |
| --- | ---: | ---: | ---: |
| Insert 10 commits at the top | 24 ms | 453 ms | 574 ms |
| Select a visible row | 17 ms | 413 ms | 17 ms |

SwiftUI compares the identities of every row whenever the list's data changes, and in a `List` a selection change costs almost as much. The cost grows with the size of the history. At 100,000 commits, selecting a row in a `List` still took 68 ms, about four frames. `NSTableView` only does work for the rows that change.

## Decision

yaga's commit list is a view-based `NSTableView` with fixed-height rows that draw themselves. yaga places it in the window with `NSViewRepresentable`, and it can use SwiftUI for the rest of the interface.

## Consequences

- The commit list's data source, row drawing, selection, keyboard handling and accessibility are AppKit code, not SwiftUI. We have to implement accessibility for rows that draw themselves, because a plain `NSView` that draws text doesn't expose it to VoiceOver.
- Updates to the list, such as new commits after a fetch, go through `NSTableView` calls like `insertRows(at:withAnimation:)` rather than through SwiftUI state. The code that bridges the two needs a clear owner for the list's data.
- Other views that can hold very large collections, such as the diff view and the file list of a large commit, should be tested the same way before we choose SwiftUI for them.
- Views with small, bounded data, such as the sidebar, settings, and commit details, can stay in SwiftUI.
