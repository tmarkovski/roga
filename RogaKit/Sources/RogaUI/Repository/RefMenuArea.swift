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
    /// Builds the menu as it opens, in place of `entries`, for a menu that needs
    /// something too slow to find out whenever the row is drawn.
    var entriesOnOpen: (() -> [RefMenu.Entry])?

    func makeNSView(context: Context) -> RefMenuAreaView {
        RefMenuAreaView()
    }

    func updateNSView(_ view: RefMenuAreaView, context: Context) {
        view.entries = entries
        view.entriesOnOpen = entriesOnOpen
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
    var entriesOnOpen: (() -> [RefMenu.Entry])?
    var opensOnClick = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let opensMenu = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && (opensOnClick || event.modifierFlags.contains(.control)))
        return opensMenu ? super.hitTest(point) : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        RefMenu.make(entriesOnOpen?() ?? entries)
    }

    override func mouseDown(with event: NSEvent) {
        guard opensOnClick else {
            super.mouseDown(with: event)
            return
        }
        openUnder()
    }

    fileprivate func openUnder() {
        RefMenu.make(entriesOnOpen?() ?? entries).popUp(positioning: nil, at: NSPoint(x: 0, y: -Self.gapUnderButton), in: self)
    }

    private static let gapUnderButton = 4.0
}

/// A menu's commands as actions for assistive apps.
@ViewBuilder func refMenuActions(_ entries: [RefMenu.Entry]) -> some View {
    let entries = withoutSubmenus(entries)
    ForEach(entries.indices, id: \.self) { index in
        switch entries[index] {
        case let .command(title, _, isEnabled, _, action):
            Button(title.plain, action: action)
                .disabled(!isEnabled)
        case let .choice(choice):
            Button(choice.title, action: choice.action)
                .disabled(!choice.isEnabled || choice.isCurrent)
        case let .option(title, isChecked, action):
            Button(title.plain, action: action)
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
        guard case let .submenu(group, _, isGroupEnabled, inner) = entry else { return [entry] }
        let named = { (row: RefMenu.Title) -> RefMenu.Title in
            let words = row.plain
            return "\(group) \(words.prefix(1).lowercased() + words.dropFirst())"
        }
        return withoutSubmenus(inner).compactMap { row -> RefMenu.Entry? in
            switch row {
            case let .command(title, isDestructive, isEnabled, shortcut, action):
                .command(named(title), isDestructive: isDestructive, isEnabled: isEnabled && isGroupEnabled, shortcut: shortcut, action: action)
            case let .option(title, isChecked, action):
                // An option has no way of saying it can't be picked.
                isGroupEnabled ? .option(named(title), isChecked: isChecked, action: action) : nil
            default:
                row
            }
        }
    }
}
