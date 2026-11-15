# 87. Sort refs from the panel's menu

Accepted on 2026-11-15. This changes the refs panel's top row, which had a button of its own for sorting refs by name or by date, and its "…" menu, which was a macOS menu.

## Context

The refs panel's top row had Filter, a Sort button, the "…" menu and, since [decision 85](0085-keep-the-refs-panels-button-in-the-windows-corner.md), the button that hides the panel. The Sort button opened a menu with only Name and Date, and the "…" menu had the same two at its top. Sorting is set once and seldom changed, so a button for it took a place in the row for little.

The sidebar's header has one button, Group and Sort, which opens one of Roga's own menus with **Group by** and **Sort by** rows that show what's chosen and open submenus ([decision 66](0066-sentence-case-branch-icons-and-the-value-on-a-row.md)).

## Decision

**The Sort button goes.** The "…" menu is one of Roga's own menus, like the sidebar's: **Sort by**, with Name or Date before its arrow and a submenu with a checkmark at the one chosen, then Filter refs, Collapse all sections and Expand all sections, then Hide refs. Filter refs and Hide refs show the menu bar's keys for them, Option-Command-F and Control-Command-I.

## Consequences

- The panel's top row has Filter, the "…" menu and the button that hides the panel.
- Sorting takes a click more, and the menu says how the refs are sorted before its submenu opens.
- The menu reads like the sidebar's, with sentence case and the value on its row, and VoiceOver finds its commands as actions on the button.
- History's Order menu keeps the sort icon the panel's button had ([decision 83](0083-open-a-new-refs-popover-where-it-was-asked-for.md)).
