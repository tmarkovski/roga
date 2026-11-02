import AppKit

/// The diff's text, which can be selected and searched but not edited. Nobody
/// sees an insertion point in text they can't edit, so the up and down arrows
/// scroll it instead of moving one.
final class DiffTextView: NSTextView {
    override func moveUp(_ sender: Any?) {
        scrollLineUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        scrollLineDown(sender)
    }
}
