# 85. Keep the refs panel's button in the window's corner

Accepted on 2026-11-15. This changes [decision 45](0045-fetch-and-new-branch-as-buttons-and-the-commit-count-with-history.md), whose title row ended with history's Order menu and then the refs panel's button.

## Context

The button that hides the refs panel sat just before the panel, at the end of history's part of the title row. The panel's own buttons, Filter, Sort and its menu, came after it, in a row as wide as the panel. Hiding the panel took that row away, so the button moved to the window's right edge, 288 to 560 points from where it was clicked. Showing the panel again meant finding it there. Clicking it twice to look at history without the panel and back didn't work without moving the pointer.

The sidebar's button doesn't move. macOS keeps it by the traffic lights whether the sidebar shows or not, and in the sidebar's own top while it does.

## Decision

**The refs panel's button is the last thing in the title row, in the window's top right corner, whether the panel shows or not.** While the panel shows, it's the last of the panel's own buttons, after its menu, so it sits in the panel it hides. While the panel is hidden, it's the title row's last item, which puts it in the same place.

**A thin line separates Fetch and New Branch from history's commands,** as tall as their icons, with as much room on each side. It shows once history has loaded. A gap was all that said Fetch and New Branch act on the branch, while the number of commits and Order act on history, and the two groups read as one.

Nothing else changes: View > Hide Refs and Control-Command-I, the panel's menu, and the button being disabled while the window is too narrow for the panel.

## Consequences

- The button stays under the pointer, so a second click undoes the first, as the sidebar's does.
- The two buttons that hide a side of the window are in its two top corners, each at the top of what it hides.
- The panel's menu is no longer last in its row.
- While the panel shows, history's Order menu ends history's part of the row, right before the panel.
