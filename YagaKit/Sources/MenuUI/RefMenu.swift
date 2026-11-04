import AppKit

/// The menu for right-clicking a ref, a commit or a row in the sidebar. It draws
/// its own rows, because an `NSMenuItem`'s title can't choose how tall its row is
/// or how wide its margins are, and it fills with the accent color rather than the
/// panels' soft gray. It's still an `NSMenu`, so macOS handles the arrow keys,
/// typing to select and closing it. Return doesn't choose a row yet, because macOS
/// doesn't run an item that has a view of its own
/// (https://github.com/tmarkovski/yaga/issues/12).
public enum RefMenu {
    public enum Entry {
        /// A dim line that names what the commands under it act on.
        case header(String)
        case command(String, isDestructive: Bool = false, isEnabled: Bool = true, action: () -> Void)
        /// A row that opens more rows beside it.
        case submenu(String, isDestructive: Bool = false, isEnabled: Bool = true, entries: [Entry])
        case divider
    }

    public static func make(_ entries: [Entry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.showsStateColumn = false
        let width = Metrics.width(fitting: entries)
        for entry in entries {
            switch entry {
            case let .header(title):
                let item = NSMenuItem.sectionHeader(title: title)
                item.view = RowView(
                    title: title,
                    font: Metrics.headerFont,
                    color: Colors.header,
                    size: NSSize(width: width, height: Metrics.headerHeight)
                )
                menu.addItem(item)
            case let .command(title, isDestructive, isEnabled, action):
                let command = Command(action)
                let item = NSMenuItem(title: title, action: #selector(Command.run), keyEquivalent: "")
                item.target = command
                // A menu item doesn't keep its target alive.
                item.representedObject = command
                item.isEnabled = isEnabled
                item.view = RowView(
                    title: title,
                    font: Metrics.commandFont,
                    color: Colors.row(isDestructive: isDestructive, isEnabled: isEnabled),
                    size: NSSize(width: width, height: Metrics.commandHeight)
                )
                menu.addItem(item)
            case let .submenu(title, isDestructive, isEnabled, entries):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = make(entries)
                item.isEnabled = isEnabled
                item.view = RowView(
                    title: title,
                    font: Metrics.commandFont,
                    color: Colors.row(isDestructive: isDestructive, isEnabled: isEnabled),
                    size: NSSize(width: width, height: Metrics.commandHeight)
                )
                menu.addItem(item)
            case .divider:
                menu.addItem(.separator())
            }
        }
        return menu
    }
}

private enum Metrics {
    static let commandHeight = 28.0
    static let headerHeight = 24.0
    static let commandFont = NSFont.systemFont(ofSize: 14)
    static let headerFont = NSFont.systemFont(ofSize: 13)
    /// From the menu's edge to its text.
    static let textInset = 16.0
    /// From the menu's edge to the fill under a highlighted row.
    static let highlightInset = 6.0
    static let highlightRadius = 9.0
    /// The arrow on a row that opens a submenu, and the room its title leaves for it.
    static let arrowSize = NSSize(width: 5, height: 10)
    static let arrowRoom = 16.0
    static let minimumWidth = 264.0
    /// A longer name gets cut short in its middle, where branch names differ least.
    static let maximumWidth = 480.0

    /// All the rows are one width, because a menu is as wide as its widest view.
    static func width(fitting entries: [RefMenu.Entry]) -> Double {
        let widest = entries.map { entry -> Double in
            switch entry {
            case let .header(title): textWidth(title, font: headerFont)
            case let .command(title, _, _, _): textWidth(title, font: commandFont)
            case let .submenu(title, _, _, _): textWidth(title, font: commandFont) + arrowRoom
            case .divider: 0
            }
        }.max() ?? 0
        return min(max(widest.rounded(.up) + 2 * textInset, minimumWidth), maximumWidth)
    }

    private static func textWidth(_ text: String, font: NSFont) -> Double {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}

/// Named colors rather than the system's label colors, because a menu's material
/// turns those dimmer than the panels' text.
private enum Colors {
    static let header = adaptive(dark: NSColor(white: 0.65, alpha: 1), light: NSColor(white: 0.45, alpha: 1))
    static let command = adaptive(dark: NSColor(white: 0.94, alpha: 1), light: NSColor(white: 0.1, alpha: 1))
    static let disabled = adaptive(dark: NSColor(white: 0.45, alpha: 1), light: NSColor(white: 0.65, alpha: 1))
    static let destructive = adaptive(
        dark: NSColor(srgbRed: 226 / 255, green: 126 / 255, blue: 124 / 255, alpha: 1),
        light: NSColor(srgbRed: 192 / 255, green: 57 / 255, blue: 43 / 255, alpha: 1)
    )
    static let highlight = adaptive(dark: NSColor(white: 1, alpha: 0.15), light: NSColor(white: 0, alpha: 0.08))

    static func row(isDestructive: Bool, isEnabled: Bool) -> NSColor {
        !isEnabled ? disabled : isDestructive ? destructive : command
    }

    private static func adaptive(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}

/// What a menu item calls when it's chosen.
private final class Command: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run(_ sender: NSMenuItem) {
        action()
    }
}

/// A row's text, and the fill under it while it's highlighted.
private final class RowView: NSView {
    /// How long after the menu opens a release still belongs to the click that
    /// opened it. Near the bottom of the screen the menu opens with its last row
    /// under the pointer, and that row can be Delete Branch.
    private static let openingClickDuration = 0.25

    private let title: String
    private let color: NSColor
    private let attributes: [NSAttributedString.Key: Any]
    private var openedAt = 0.0

    init(title: String, font: NSFont, color: NSColor, size: NSSize) {
        self.title = title
        self.color = color
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        attributes = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        super.init(frame: NSRect(origin: .zero, size: size))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) {
        fatalError("The rows are made in code.")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { openedAt = ProcessInfo.processInfo.systemUptime }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let item = enclosingMenuItem, item.isHighlighted, item.isEnabled {
            Colors.highlight.setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: Metrics.highlightInset, dy: 0),
                xRadius: Metrics.highlightRadius,
                yRadius: Metrics.highlightRadius
            ).fill()
        }
        let hasArrow = enclosingMenuItem?.hasSubmenu == true
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(
            in: NSRect(
                x: Metrics.textInset,
                y: (bounds.height - height) / 2,
                width: bounds.width - 2 * Metrics.textInset - (hasArrow ? Metrics.arrowRoom : 0),
                height: height
            ),
            withAttributes: attributes
        )
        if hasArrow { drawArrow() }
    }

    private func drawArrow() {
        let tip = NSPoint(x: bounds.maxX - Metrics.textInset, y: bounds.midY)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: tip.x - Metrics.arrowSize.width, y: tip.y + Metrics.arrowSize.height / 2))
        arrow.line(to: tip)
        arrow.line(to: NSPoint(x: tip.x - Metrics.arrowSize.width, y: tip.y - Metrics.arrowSize.height / 2))
        arrow.lineWidth = 1.5
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        color.setStroke()
        arrow.stroke()
    }

    // A view in a menu gets the clicks that its item would have handled, including
    // the release of a right-click that was dragged here.
    override func mouseUp(with event: NSEvent) {
        choose(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        choose(event)
    }

    private func choose(_ event: NSEvent) {
        guard event.timestamp - openedAt > Self.openingClickDuration,
              let item = enclosingMenuItem, item.isEnabled, !item.hasSubmenu, let menu = item.menu
        else { return }
        // A row in a submenu closes the menu it came from too.
        var outermost = menu
        while let parent = outermost.supermenu { outermost = parent }
        outermost.cancelTracking()
        menu.performActionForItem(at: menu.index(of: item))
    }
}
