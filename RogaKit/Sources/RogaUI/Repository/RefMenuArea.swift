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
    /// What opens the menu without a click, as VoiceOver's press does.
    var opener: RefMenuOpener?

    func makeNSView(context: Context) -> RefMenuAreaView {
        RefMenuAreaView()
    }

    func updateNSView(_ view: RefMenuAreaView, context: Context) {
        view.entries = entries
        view.opensOnClick = opensOnClick
        opener?.view = view
    }
}

/// Opens a `RefMenuArea`'s menu under it, for a view that's pressed some other
/// way than with a click.
final class RefMenuOpener {
    fileprivate weak var view: RefMenuAreaView?

    func open() {
        view?.openUnder()
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
        openUnder()
    }

    fileprivate func openUnder() {
        RefMenu.make(entries).popUp(positioning: nil, at: NSPoint(x: 0, y: -Self.gapUnderButton), in: self)
    }

    private static let gapUnderButton = 4.0
}

/// A menu's commands as actions for assistive apps.
@ViewBuilder func refMenuActions(_ entries: [RefMenu.Entry]) -> some View {
    let entries = withoutSubmenus(entries)
    ForEach(entries.indices, id: \.self) { index in
        switch entries[index] {
        case let .command(title, _, isEnabled, _, action):
            Button(title, action: action)
                .disabled(!isEnabled)
        case let .choice(choice):
            Button(choice.title, action: choice.action)
                .disabled(!choice.isEnabled || choice.isCurrent)
        case let .option(title, isChecked, action):
            Button(title, action: action)
                .disabled(isChecked)
        case .header, .divider, .submenu:
            EmptyView()
        }
    }
}

/// A submenu's commands in its place, each with the submenu's name in front, since
/// a list of actions has no levels.
private func withoutSubmenus(_ entries: [RefMenu.Entry]) -> [RefMenu.Entry] {
    entries.flatMap { entry -> [RefMenu.Entry] in
        guard case let .submenu(group, isGroupEnabled, inner) = entry else { return [entry] }
        return withoutSubmenus(inner).map { row in
            guard case let .command(title, isDestructive, isEnabled, shortcut, action) = row else { return row }
            return .command("\(group) \(title)", isDestructive: isDestructive, isEnabled: isEnabled && isGroupEnabled, shortcut: shortcut, action: action)
        }
    }
}
