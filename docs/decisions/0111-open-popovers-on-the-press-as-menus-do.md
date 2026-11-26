# 111. Open popovers on the press, as menus do

Accepted on 2026-11-26. This makes the popovers that a control only opens come up the way Roga's own menus already did, and in the title row it gives up part of [decision 96](0096-draw-the-title-row-at-44-points.md)'s rule that a press there never starts moving the window. It came from [issue 122](https://github.com/tmarkovski/roga/issues/122).

## Context

Roga's own menus open as soon as the mouse button goes down, as the Mac's pop-up buttons do: a row's ⋯, the sidebar's Group, Sort and Show button, and the ⋯ on each card in the agent popover all open that way, through `RefMenuArea`. Its popovers waited until the button came back up, because they're opened from SwiftUI buttons and tap gestures, which act on the release. Next to each other, the difference was easy to feel. Generate's chevron waited for the release before the agent popover opened, and then the ⋯ inside that popover opened on the press.

`SelectsOnPress`, which selects a tab on the press, can't open a popover, because the button's own action still runs on the release and would close it again.

In the title row, decision 96 found that a press on anything but a button can start moving the window. A popover that opens during the press does too: when the drag starts in the row's top 32 points, which are macOS's own title bar, the window moves. A first version tried to keep it still, with an AppKit view of no size at the control's corner, a local event monitor, and a release made up far away from the control, so that the button wouldn't act on it. The window moved anyway, whether the popover opened before the window had the press or just after, with the press or the drag kept back, and with `isMovable` turned off on the press. A press that opens a popover matters more than that drag, so the simpler way won.

## Decision

**A control whose only job is to open a popover opens it as the mouse button goes down.** That's Add Repositories at the top of the sidebar, the identity at the end of the title row and the line at the top of the message box, the chevrons on Generate, Resolve, Fix, Fix with Claude and Try Again, New Branch, the + after the tabs, the agent's line in the branch row, and the chevron in the Key field. The gray that marks an open control follows the popover, so it shows from the press. Pressing the control again while the popover is open closes it, once the mouse button comes back up, as it did before: the popover is the key window then, and AppKit holds that press until the release. Escape and a click elsewhere close the popover as before, and Space, Return and VoiceOver's press still open it through the control's own button.

**Push buttons with words stay on the release,** as the Mac's do, so a press can still be dragged off to cancel, even when they open a popover: Set Identity… and Set Key… in the message box's warning, Set… in Settings › Git, Trust This Key…, and New SSH Key… and New OpenPGP Key…. So do the main parts of Generate, Resolve and Fix, which run an agent rather than open anything. So every menu and popover that a control only opens comes up on the press, and what a button's words name happens on the release.

**`opensOnPress` takes the press the way `RefMenuArea` does.** An AppKit view over the control takes a left mouse-down and lets every other event through, so hover, tooltips and right-clicks reach the control. It opens the popover, or closes it if it's open. The control never sees the press, so its own button doesn't act again as the mouse button comes up. A disabled control does nothing on the press and keeps its tooltip, which says why. While another popover is open, a press on the control only closes that popover, as a press on a button does.

## Consequences

- Every control in Roga that only opens a menu or a popover opens it on the press.
- Popovers that a menu's row opens, such as Create in history or New Worktree… in a row's menu, are unchanged. They open as the row is chosen, and the menu already opens on the press.
- In the title row's top 32 points, a drag that starts on the identity or the + moves the window, as one that starts on a tab already did, because of the `RefMenuArea` over each tab for its menu.
- A control looks pressed only through its open popover's gray, since the control itself never sees the press.
- Selecting a repository's row in the sidebar on the press, as a tab does, is a separate question, about selecting rather than popovers.
