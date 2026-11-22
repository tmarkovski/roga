# 96. Draw the title row ourselves, 44 points tall

Accepted on 2026-11-22. This changes how [decision 95](0095-a-repositorys-worktrees-as-tabs.md)'s title row and [decision 85](0085-keep-the-refs-panels-button-in-the-windows-corner.md)'s button are made, which were items in the window's toolbar.

## Context

The Claude app's rows of tabs and commands are 44 points tall, with 32-point tabs and buttons. Roga's panel headers and the branch's row went to 44 points to match, with 32-point buttons, but the row along the top of the window stayed at 40, with the tabs 4 points from its top and bottom where the Claude app has 6.

That row was the window's toolbar, and macOS decides a toolbar's height: 40 points in the compact style Roga used, and 52 in the other. A taller item doesn't make a compact toolbar taller, and AppKit has no setting for it. The toolbar also cost Roga work of its own:

- The refs panel's part of the row was a toolbar item exactly as wide as the panel, worked out from the toolbar's margins, which were measured on macOS 27.
- The button that hides the panel kept its place only because of an inset measured the same way (decision 85).
- The tabs had to tell the toolbar how wide they could be, and make it measure them again, or it moved what didn't fit into a menu of its own.
- A right-click on a tab went to the toolbar, for the toolbar's own menu, and never reached the tab.

## Decision

**The window has no title bar or toolbar of its own, and Roga draws the row along its top, 44 points tall, like a panel's header.** It's in three parts, each at the top of the column it belongs to:

- **The sidebar's part** has the traffic lights, then the button that hides the sidebar.
- **The middle's part** has the tabs, with the same thin line along its bottom as a panel's header. While the sidebar is hidden, it starts with the traffic lights and the sidebar's button, where the sidebar has them. While the refs panel is hidden, it ends with the panel's button.
- **The refs panel's part** is the panel's own header, with its commands at its end and the button that hides it last.

**The traffic lights sit in the row's middle,** 17 points from the window's edge, as in the Claude app, with 7 points between them and the fill of the sidebar's button. macOS places them for a title bar of its own and puts them back as it lays the window out again, such as when the sidebar shows or hides, so Roga makes macOS's title bar as tall as the row, moves them, and moves them again each time macOS does. It moves them back as soon as macOS moves them, before the window draws them, or they'd show in macOS's corner for a moment. In full screen, where they slide down with the menu bar, they're left to macOS, and the row keeps no room for them.

**The empty parts of the row still move the window,** and double-clicking them does what the user chose in System Settings. macOS's title bar, now as tall as the row, does both, as it did before. Anything in the row that's clicked is a button, because the title bar takes a press on anything else for the start of moving the window. So a tab is a button that selects it as the mouse button goes down.

## Consequences

- The row is as tall as the Claude app's, and the tabs and buttons have the same room above and below them.
- The button that hides the refs panel stays put because both rows end it at the same inset, rather than because of measurements of macOS's toolbar. The same goes for the sidebar's button.
- The tabs take what room the row has, like any other view, and get narrower when it's short, without the toolbar moving any of them into a menu.
- A right-click or a Control-click on a tab reaches it, so its menu opens without the workaround that watched for those clicks.
- Roga depends on how macOS lays out its title bar: the views the traffic lights are in, and when it moves them. A version of macOS that changes either could put them back where it wants them, or somewhere else, and this would need changing.
- Setup keeps room for the row at its top, with its dots in the row's middle, as before.
