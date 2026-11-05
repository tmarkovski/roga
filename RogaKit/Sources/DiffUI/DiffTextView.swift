import AppKit

/// The diff's text, which can be selected and searched but not edited. Nobody
/// sees an insertion point in text they can't edit, so the up and down arrows
/// scroll it instead of moving one.
final class DiffTextView: NSTextView {
    /// What right-clicking a place in the text offers beside what text views do.
    var menuItem: ((NSPoint) -> NSMenuItem?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        // A copy, because a text view's menu can be shared by all of them.
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        if let item = menuItem?(convert(event.locationInWindow, from: nil)) {
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    override func moveUp(_ sender: Any?) {
        scrollLineUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        scrollLineDown(sender)
    }
}
