# 9. Show diffs in a TextKit 1 text view

Accepted on 2026-11-01.

## Context

Decision 7 said that views which can hold very large collections should be tested before we choose how to build them. The diff view is one of them. The [diff view test](../../prototypes/git-access/RESULTS.md#the-diff-view) used the diff from Linux v6.0 to v6.1, which changes 12,914 files and 1.29 million lines. It compared three ways to show a diff: an `NSTableView` with one self-drawn row per line, an `NSTextView` using TextKit 2, and an `NSTextView` using TextKit 1 with non-contiguous layout.

For the largest file in that diff, a 40,325-line patch:

- The table prepared in 2 ms and scrolled smoothly.
- TextKit 1 prepared in 58 ms and scrolled smoothly.
- TextKit 2 performed well only with lines wrapped. Unwrapped, it took about a second to prepare and stalled while scrolling, for up to a second, in every setup we tried.

For the whole diff as one document, the table and both text systems scrolled smoothly. The text views spent 1.1 seconds building attributed text first and used about 480 MB, against 1 ms and 273 MB for the table.

An `NSTextView` provides selection across lines, copying, the find bar, and VoiceOver support. A table provides none of these, so yaga would have to build them itself.

## Decision

yaga shows the content of a diff in an `NSTextView` that uses TextKit 1 with non-contiguous layout. Diffs don't wrap. The list of changed files comes first, as the roadmap plans, and the text view holds the patch for the selected file or files rather than a whole large diff at once.

## Consequences

- Selection, copying, find, and accessibility in the diff come from AppKit rather than from our own code.
- Line numbers and backgrounds that span the full width of a line need custom drawing, through a ruler view and an `NSLayoutManager` subclass. That drawing cost wasn't measured in the prototype.
- yaga creates the text view with TextKit 1 explicitly. Code that works with it must never let TextKit 2 sneak in, and code that works with any TextKit 2 view must never ask it for its `layoutManager`, because that silently switches the view to TextKit 1.
- Building the attributed text for a very large selection takes time, about 1.1 seconds for a whole Linux release, so yaga should build it in the background or in pieces when a selection is large.
- TextKit 1 is the older text system, and Apple's direction is TextKit 2. We should revisit this decision if TextKit 2's handling of unwrapped text improves.
- If yaga ever needs to show a diff as large as a whole Linux release in one continuous view, a table is the faster option, at the cost of building selection and find ourselves.
