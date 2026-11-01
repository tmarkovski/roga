import AppKit
import SwiftUI

/// Sets up the window that hosts a repository so that it opens as a tab, and
/// keeps the tab's tooltip and accessory view up to date.
struct TabConfigurator: NSViewRepresentable {
    let toolTip: String
    let changeSummary: String?

    func makeNSView(context: Context) -> TabConfiguratorView {
        TabConfiguratorView()
    }

    func updateNSView(_ view: TabConfiguratorView, context: Context) {
        view.tabToolTip = toolTip
        view.changeSummary = changeSummary
        view.apply()
    }
}

final class TabConfiguratorView: NSView {
    var tabToolTip = ""
    var changeSummary: String?
    private var joinedTabs = false

    private lazy var changesDot: NSImageView = {
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Uncommitted changes")?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .regular))
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = .systemOrange
        return view
    }()

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard let newWindow else { return }
        // `.preferred` opens the window as a tab even when the system setting
        // "Prefer tabs when opening documents" is set to "In Full Screen" or "Never".
        newWindow.tabbingIdentifier = WindowTabbing.repositoryIdentifier
        newWindow.tabbingMode = .preferred
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
        guard let window, !joinedTabs else { return }
        joinedTabs = true
        DispatchQueue.main.async { WindowTabbing.joinExistingTabGroup(window) }
    }

    func apply() {
        guard let window else { return }
        window.tab.toolTip = tabToolTip.isEmpty ? nil : tabToolTip
        if let changeSummary {
            changesDot.toolTip = changeSummary
            if window.tab.accessoryView !== changesDot { window.tab.accessoryView = changesDot }
        } else if window.tab.accessoryView != nil {
            window.tab.accessoryView = nil
        }
    }
}

enum WindowTabbing {
    static let repositoryIdentifier = "build.yaga.repository"

    static func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["YAGA_TABS_DEBUG"] != nil else { return }
        FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    }

    /// AppKit only tabs a new window into the key window. When the key window is
    /// something else, such as the welcome window, add the new window to an
    /// existing repository tab group ourselves.
    static func joinExistingTabGroup(_ window: NSWindow) {
        debug("join \(window.title): group \(window.tabGroup?.windows.map(\.title) ?? [])")
        guard (window.tabbedWindows?.count ?? 1) <= 1 else { return }
        let others = NSApp.windows.filter {
            $0 !== window && $0.isVisible && $0.tabbingIdentifier == repositoryIdentifier
        }
        guard let target = others.first(where: { $0.isKeyWindow || $0.isMainWindow }) ?? others.first else { return }
        let last = target.tabGroup?.windows.last ?? target
        last.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }
}
