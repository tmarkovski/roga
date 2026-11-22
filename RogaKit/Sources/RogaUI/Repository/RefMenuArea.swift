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
    /// Whether it's in the window's toolbar, as a worktree's tab is, where the
    /// window keeps right-clicks and Control-clicks from it.
    var isInToolbar = false

    func makeNSView(context: Context) -> RefMenuAreaView {
        RefMenuAreaView()
    }

    func updateNSView(_ view: RefMenuAreaView, context: Context) {
        view.entries = entries
        view.entriesOnOpen = entriesOnOpen
        view.opensOnClick = opensOnClick
        view.isInToolbar = isInToolbar
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
    var isInToolbar = false {
        didSet {
            if isInToolbar != oldValue { watchContextClicks() }
        }
    }
    private var contextClickMonitor: Any?

    isolated deinit {
        if let contextClickMonitor { NSEvent.removeMonitor(contextClickMonitor) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watchContextClicks()
    }

    /// The window hands a right-click or a Control-click in its toolbar to the
    /// toolbar, for the toolbar's own menu, even when it lands on a view with a
    /// menu of its own, so the view never hears of it, and Roga's toolbar has no
    /// menu. So in the toolbar, the view watches for those clicks itself, before
    /// the window sees them, and opens its menu for the ones that land on it. It
    /// can't tell it's in the toolbar from where it is, because in full screen
    /// the toolbar moves to a window of its own, whose content it's in.
    private func watchContextClicks() {
        if let contextClickMonitor { NSEvent.removeMonitor(contextClickMonitor) }
        contextClickMonitor = nil
        guard isInToolbar, window != nil else { return }
        contextClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, isContextClick(onSelf: event), let menu = menu(for: event) else { return event }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return nil
        }
    }

    /// Whether a click opens a menu rather than pressing what's under it, and
    /// lands on this view rather than on something over it.
    private func isContextClick(onSelf event: NSEvent) -> Bool {
        let opensMenu = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard opensMenu, let window, event.windowNumber == window.windowNumber,
              let frameView = window.contentView?.superview else { return false }
        return frameView.hitTest(event.locationInWindow) === self
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let opensMenu = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && (opensOnClick || event.modifierFlags.contains(.control)))
        return opensMenu ? super.hitTest(point) : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // A popover that a command in it opens, such as New branch from
        // stash…'s, hangs from the row (decision 83).
        MenuAnchor.opened(in: self, at: bounds)
        return RefMenu.make(entriesOnOpen?() ?? entries)
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        MenuAnchor.closed()
    }

    override func mouseDown(with event: NSEvent) {
        guard opensOnClick else {
            super.mouseDown(with: event)
            return
        }
        openUnder()
    }

    fileprivate func openUnder() {
        MenuAnchor.opened(in: self, at: bounds)
        RefMenu.make(entriesOnOpen?() ?? entries).popUp(positioning: nil, at: NSPoint(x: 0, y: -Self.gapUnderButton), in: self)
        MenuAnchor.closed()
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
