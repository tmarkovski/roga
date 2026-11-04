import AppKit
import MenuUI
import SwiftUI

/// Opens a row's menu for a right-click or a Control-click, and lets every other
/// event through to the row. SwiftUI's own context menu can't show `RefMenu`'s
/// rows, since it builds its menu's items itself.
struct RefMenuArea: NSViewRepresentable {
    let entries: [RefMenu.Entry]
    /// Whether a plain click opens the menu too, under the view, as a button does.
    var opensOnClick = false

    func makeNSView(context: Context) -> RefMenuAreaView {
        RefMenuAreaView()
    }

    func updateNSView(_ view: RefMenuAreaView, context: Context) {
        view.entries = entries
        view.opensOnClick = opensOnClick
    }
}

final class RefMenuAreaView: NSView {
    var entries: [RefMenu.Entry] = []
    var opensOnClick = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let opensMenu = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && (opensOnClick || event.modifierFlags.contains(.control)))
        return opensMenu ? super.hitTest(point) : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        RefMenu.make(entries)
    }

    override func mouseDown(with event: NSEvent) {
        guard opensOnClick else {
            super.mouseDown(with: event)
            return
        }
        RefMenu.make(entries).popUp(positioning: nil, at: NSPoint(x: 0, y: -Self.gapUnderButton), in: self)
    }

    private static let gapUnderButton = 4.0
}

/// A menu's commands as actions for assistive apps.
@ViewBuilder func refMenuActions(_ entries: [RefMenu.Entry]) -> some View {
    ForEach(entries.indices, id: \.self) { index in
        if case let .command(title, _, isEnabled, action) = entries[index] {
            Button(title, action: action)
                .disabled(!isEnabled)
        }
    }
}
