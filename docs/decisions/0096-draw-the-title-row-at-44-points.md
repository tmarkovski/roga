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

**The window has no title bar or toolbar of its own, and Roga draws the row along its top, 44 points tall, like a panel's header.** It's in three parts, each at the top of the column it belongs to, with the traffic lights and the sidebar's button over them:

- **The traffic lights and the sidebar's button** stay in the window's top left corner, over whichever column is there, whether the sidebar shows or not. Neither column has them, so they don't move as the sidebar shows or hides, and nothing slides under them.
- **The sidebar's part** is empty, under the traffic lights and the button.
- **The middle's part** has the tabs, with the same thin line along its bottom as a panel's header. The tabs keep clear of the traffic lights and the sidebar's button wherever the middle is: while the sidebar is hidden, and for the frame or two after the sidebar is asked to show, before the split view moves the middle over. While the refs panel is hidden, the row ends with the panel's button.
- **The refs panel's part** is the panel's own header, with its commands at its end and the button that hides it last.

**The traffic lights are Roga's own,** in the row's middle, 17 points from the window's edge as in the Claude app, with 7 points between them and the fill of the sidebar's button. macOS keeps the window's own in a title bar of its own height, and puts them back in its corner each time it lays that out again, such as when the window's title changes or the sidebar shows or hides. Moving them back after macOS did left a frame or two drawn with them in the corner, which showed as a flash of the green button when switching repositories. So the window's own stay hidden, and macOS makes another set with `NSWindow.standardWindowButton(_:for:)`, which Roga lays out like any other view. They close, minimize and zoom the window and gray out when it isn't key, and macOS takes them for the window's own, so accessibility finds them as its close, minimize and full-screen buttons. To show their symbols while the pointer is over them, they ask the view they're in, with a method only macOS's title bar answers, and only when they're told the pointer came or went, with a method of theirs that the title bar calls. Roga's view answers the first and calls the second, if the buttons have it. In full screen, where the title bar slides down with the menu bar, the window's own buttons show there, Roga's don't, and the row keeps no room for them.

**Dragging the empty parts of the row moves the window.** Over its top 32 points, that's macOS's own title bar, at its own height, which also does what the user chose in System Settings for a double-click. Below that, a view behind the row's empty parts moves the window itself, since making macOS's title bar view as tall as the row didn't make macOS take clicks there for the title bar's, and a strip added under the title bar drew over the middle's row. A double-click there does nothing. macOS recognizes a double-click only as it arrives at its title bar, so handing one over from the row didn't work, and Roga can't do every choice in System Settings itself, since AppKit has no public way to Fill. Anything in the row that's clicked is a button, because the title bar takes a press on anything else for the start of moving the window. So a tab is a button that selects it as the mouse button goes down.

## Consequences

- The row is as tall as the Claude app's, and the tabs and buttons have the same room above and below them.
- The traffic lights never move when macOS lays out its title bar again, since they aren't in it, and the tabs never slide under them as the sidebar shows or hides.
- The sidebar's button stays put because it's in the window's corner rather than in either column. The refs panel's stays put because both rows end it at the same inset, rather than because of measurements of macOS's toolbar.
- The tabs take what room the row has, like any other view, and get narrower when it's short, without the toolbar moving any of them into a menu.
- A right-click or a Control-click on a tab reaches it, so its menu opens without the workaround that watched for those clicks.
- Roga depends on macOS in ways a later version could change: the two methods behind the buttons' symbols, without which they'd show none on hover, and the window's own buttons, which it finds through the window before adding its own. It no longer depends on how macOS lays out its title bar.
- Setup has the traffic lights in the same place, with its dots in the row's middle, as before.
