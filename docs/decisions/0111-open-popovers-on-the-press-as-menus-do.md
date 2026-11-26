# 111. Open popovers on the press, as menus do

Accepted on 2026-11-26. This makes the popovers that a control only opens come up the way Roga's own menus already did, and keeps to [decision 96](0096-draw-the-title-row-at-44-points.md)'s rule that what's clicked in the title row is a button. It came from [issue 122](https://github.com/tmarkovski/roga/issues/122).

## Context

Roga's own menus open as soon as the mouse button goes down, as the Mac's pop-up buttons do: a row's ⋯, the sidebar's Group, Sort and Show button, and the ⋯ on each card in the agent popover all open that way, through `RefMenuArea`. Its popovers waited until the button came back up, because they're opened from SwiftUI buttons and tap gestures, which act on the release. Next to each other, the difference was easy to feel. Generate's chevron waited for the release before the agent popover opened, and then the ⋯ inside that popover opened on the press.

Taking the press the way `RefMenuArea` does, with an AppKit view over the control, works everywhere but the title row. There, decision 96 found that a press on anything but a button can start moving the window, and trying it again found more:

- **A drag that starts on an AppKit view over a control moves the window.** One that starts on a tab does today, since each tab has `RefMenuArea` over it for its menu.
- **A press that the window never sees moves it too.** Kept back as it arrives, macOS starts moving the window a few points into the drag.
- **A popover that opens during the press moves it as well,** when the drag starts in the row's top 32 points, which are macOS's own title bar. That held however the press was taken, whether the popover opened before the window had the press or just after, and with `isMovable` turned off on the press.

Two more things got in the way. While a popover is open, it's the key window, and AppKit holds a press on the control it hangs from until the mouse button comes back up, and only then closes the popover. And `SelectsOnPress`, which selects a tab on the press, can't open a popover, because the button's own action still runs on the release and would close it again.

## Decision

**A control whose only job is to open a popover opens it as the mouse button goes down, and a press on it while the popover is open closes it.** That's Add Repositories at the top of the sidebar, the identity at the end of the title row and the line at the top of the message box, the chevrons on Generate, Resolve, Fix, Fix with Claude and Try Again, New Branch, the + after the tabs, the agent's line in the branch row, and the chevron in the Key field. The gray that marks an open control follows the popover, so it shows from the press. Escape and a click elsewhere close the popover as before, and Space, Return and VoiceOver's press still open it through the control's own button.

**Push buttons with words stay on the release,** as the Mac's do, so a press can still be dragged off to cancel, even when they open a popover: Set Identity… and Set Key… in the message box's warning, Set… in Settings › Git, Trust This Key…, and New SSH Key… and New OpenPGP Key…. So do the main parts of Generate, Resolve and Fix, which run an agent rather than open anything. So every menu and popover that a control only opens comes up on the press, and what a button's words name happens on the release.

**The press is found as it arrives, from a corner of the control.** `opensOnPress` puts an AppKit view with no size at the control's top left corner, and SwiftUI tells it the control's size, so the control stays the only thing under the pointer, and hover, tooltips and right-clicks reach it as before. The view watches with a local event monitor for a press inside the control, and opens or closes the popover. The press goes on to the window, since one the window never sees moves it in the title row. The drag after it goes nowhere. The window gets the release far away from the control, so the control's own button doesn't act again, as a button released outside itself doesn't, and the window then lets the popover take the keyboard, and Escape with it. A disabled control does nothing on the press and keeps its tooltip, which says why. While another popover is open, a press on the control only closes that popover, as a press on a button does.

## Consequences

- Every control in Roga that only opens a menu or a popover opens it on the press.
- Popovers that a menu's row opens, such as Create in history or New Worktree… in a row's menu, are unchanged. They open as the row is chosen, and the menu already opens on the press.
- In the row's top 32 points, a drag that starts on the identity or the + moves the window, which a drag from the same button didn't while it opened its popover on the release. Nothing tried so far keeps it still.
- The tabs still move the window when a drag starts on one, because of the view over them for their menus. That's left for another change.
- Each of these controls has a local event monitor while it's in a window, which looks at every press, drag and release of the left mouse button there.
- Selecting a repository's row in the sidebar on the press, as a tab does, is a separate question, about selecting rather than popovers.
