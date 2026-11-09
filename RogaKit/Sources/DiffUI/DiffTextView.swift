import AppKit

/// The diff's text, which can be selected and searched but not edited. Nobody
/// sees an insertion point in text they can't edit, so the up and down arrows
/// scroll it instead of moving one.
final class DiffTextView: NSTextView {
    /// What right-clicking a place in the text offers beside what text views do.
    var menuItem: ((NSPoint) -> NSMenuItem?)?
    /// Whether something sits over the text at a place in the window, such as a
    /// button on a band.
    var isCovered: ((NSPoint) -> Bool)?

    override func menu(for event: NSEvent) -> NSMenu? {
        // A copy, because a text view's menu can be shared by all of them.
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        // Otherwise macOS 27 puts Ask Siri above everything else in it.
        menu.allowsContextMenuPlugIns = false
        menu.automaticallyInsertsWritingToolsItems = false
        if let item = menuItem?(convert(event.locationInWindow, from: nil)) {
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    // A text view can put up its text cursor as the pointer moves over it, even
    // where something else is on top.
    override func mouseMoved(with event: NSEvent) {
        if isCovered?(event.locationInWindow) == true {
            NSCursor.arrow.set()
        } else {
            super.mouseMoved(with: event)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isCovered?(event.locationInWindow) == true {
            NSCursor.arrow.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func moveUp(_ sender: Any?) {
        scrollLineUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        scrollLineDown(sender)
    }
}
