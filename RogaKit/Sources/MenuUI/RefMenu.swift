import AppKit
import IconUI

/// The menu for right-clicking a ref, a commit or a row in the sidebar, for
/// choosing one of a repository's worktrees, and for choosing how a list is
/// arranged. It draws its own rows, because an
/// `NSMenuItem`'s title can't choose how tall its row is or how wide its margins
/// are, and it fills with the accent color rather than the panels' soft gray. It's
/// still an `NSMenu`, so macOS handles the arrow keys, typing to select and closing
/// it. macOS ignores Return while a row that draws itself is highlighted, so the
/// rows hear it themselves (https://github.com/tmarkovski/yaga/issues/12).
public enum RefMenu {
    public enum Entry {
        /// A dim line that names what the commands under it act on.
        case header(String)
        case command(String, isDestructive: Bool = false, isEnabled: Bool = true, action: () -> Void)
        /// One of a set of ways to do something, such as how a list is sorted,
        /// with a checkmark at the right of the one that's chosen.
        case option(String, isChecked: Bool, action: () -> Void)
        /// One of several places to go, such as a worktree, with what's going on
        /// there on a second line.
        case choice(Choice)
        case divider
    }

    /// A row on two lines: an icon and a title, the details under the title, and a
    /// count at the end.
    public struct Choice {
        public var title: String
        public var icon: NSImage?
        /// The second line's parts, which it joins with `·`.
        public var details: [Detail]
        /// A number at the end of the row, such as how many files have changed.
        public var count: Count?
        /// Whether it's where you are already, which a checkmark says.
        public var isCurrent: Bool
        public var isEnabled: Bool
        /// What a pointer resting on the row shows, such as a folder's whole path.
        public var help: String?
        public var action: () -> Void

        public init(
            title: String,
            icon: NSImage? = nil,
            details: [Detail] = [],
            count: Count? = nil,
            isCurrent: Bool = false,
            isEnabled: Bool = true,
            help: String? = nil,
            action: @escaping () -> Void
        ) {
            self.title = title
            self.icon = icon
            self.details = details
            self.count = count
            self.isCurrent = isCurrent
            self.isEnabled = isEnabled
            self.help = help
            self.action = action
        }

        /// The second line as one piece of text, as in `↑2 · ~/agents/fix-login`.
        public var detailText: String {
            details.map(\.text).joined(separator: Metrics.separator)
        }
    }

    /// A part of a choice's second line. It's dim unless it has a color of its own.
    public struct Detail: Equatable {
        public var text: String
        public var color: NSColor?
        /// Whether it may get shorter, at its end, when the line is too long,
        /// so that the parts that can't, such as a worktree's conflicts, stay
        /// whole.
        public var canBeCutShort: Bool

        public init(_ text: String, color: NSColor? = nil, canBeCutShort: Bool = false) {
            self.text = text
            self.color = color
            self.canBeCutShort = canBeCutShort
        }
    }

    /// The number at the end of a choice, with an icon in front of it if it needs one.
    public struct Count: Equatable {
        public var text: String
        public var color: NSColor
        public var icon: NSImage?

        public init(_ text: String, color: NSColor, icon: NSImage? = nil) {
            self.text = text
            self.color = color
            self.icon = icon
        }
    }

    public static func make(_ entries: [Entry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.showsStateColumn = false
        // In a menu of choices, every title starts where the choices' titles do.
        let hasChoices = entries.contains { if case .choice = $0 { true } else { false } }
        let inset = hasChoices ? Metrics.choiceTextInset : Metrics.textInset
        let width = Metrics.width(fitting: entries, inset: inset)
        let commandSize = NSSize(width: width, height: Metrics.commandHeight)
        for entry in entries {
            switch entry {
            case let .header(title):
                let item = NSMenuItem.sectionHeader(title: title)
                item.view = RowView(
                    title: title,
                    font: Metrics.headerFont,
                    color: Colors.header,
                    inset: inset,
                    size: NSSize(width: width, height: Metrics.headerHeight)
                )
                menu.addItem(item)
            case let .command(title, isDestructive, isEnabled, action):
                let item = item(title: title, isEnabled: isEnabled, action: action)
                item.view = RowView(
                    title: title,
                    font: Metrics.commandFont,
                    color: Colors.row(isDestructive: isDestructive, isEnabled: isEnabled),
                    inset: inset,
                    size: commandSize
                )
                menu.addItem(item)
            case let .option(title, isChecked, action):
                let item = item(title: title, isEnabled: true, action: action)
                // Drawn by the row, and read by VoiceOver from the item.
                item.state = isChecked ? .on : .off
                item.view = RowView(title: title, font: Metrics.commandFont, color: Colors.command, inset: inset, size: commandSize, isChecked: isChecked)
                menu.addItem(item)
            case let .choice(choice):
                let item = item(title: choice.title, isEnabled: choice.isEnabled, action: choice.action)
                // Drawn by the row, and read by VoiceOver from the item.
                item.state = choice.isCurrent ? .on : .off
                item.view = ChoiceView(choice: choice, size: NSSize(width: width, height: Metrics.choiceHeight))
                menu.addItem(item)
            case .divider:
                menu.addItem(.separator())
            }
        }
        return menu
    }

    private static func item(title: String, isEnabled: Bool, action: @escaping () -> Void) -> NSMenuItem {
        let command = Command(action)
        let item = NSMenuItem(title: title, action: #selector(Command.run), keyEquivalent: "")
        item.target = command
        // A menu item doesn't keep its target alive.
        item.representedObject = command
        item.isEnabled = isEnabled
        return item
    }
}

private enum Metrics {
    static let commandHeight = 28.0
    static let headerHeight = 24.0
    static let choiceHeight = 44.0
    static let commandFont = NSFont.systemFont(ofSize: 14)
    static let headerFont = NSFont.systemFont(ofSize: 13)
    static let titleFont = NSFont.systemFont(ofSize: 14)
    static let detailFont = NSFont.systemFont(ofSize: 12)
    static let countFont = NSFont.systemFont(ofSize: 13)
    /// Between a choice's title and its details.
    static let lineGap = 1.0
    static let separator = " · "
    /// From the menu's edge to its text.
    static let textInset = 16.0
    /// From the menu's edge to the middle of a choice's checkmark, and of its icon.
    static let checkCenter = 19.0
    static let iconCenter = 38.0
    /// From the menu's edge to a choice's text, past its checkmark and icon.
    static let choiceTextInset = 52.0
    /// Between a choice's text and its count, and in the count, between the
    /// icon and the number.
    static let countGap = 12.0
    static let countIconGap = 3.0
    /// From the menu's edge to the fill under a highlighted row.
    static let highlightInset = 6.0
    static let highlightRadius = 9.0
    static let minimumWidth = 264.0
    /// A menu of options only, such as how to sort a list, has short titles,
    /// so it can be narrower.
    static let minimumOptionsWidth = 180.0
    /// From the menu's right edge to the middle of an option's checkmark,
    /// which ends where text would, and what an option takes for it after its
    /// title.
    static let optionCheckCenter = textInset + 7
    static let optionCheckRoom = 30.0
    /// A longer name gets cut short in its middle, where branch names differ least.
    static let maximumWidth = 480.0
    /// What a choice's last part, such as a folder, keeps when the parts
    /// before it are cut short: about 14 characters, cut in their middle, so
    /// that a folder still shows the start of its path and the end of its name.
    static let foldersRoom = 80.0
    /// The least a part that's cut short keeps, which is a few characters and
    /// the ellipsis.
    static let leastOfACutPart = 24.0

    /// All the rows are one width, because a menu is as wide as its widest view.
    static func width(fitting entries: [RefMenu.Entry], inset: Double) -> Double {
        let widest = entries.map { entry -> Double in
            switch entry {
            case let .header(title): inset + textWidth(title, font: headerFont)
            case let .command(title, _, _, _): inset + textWidth(title, font: commandFont)
            case let .option(title, _, _): inset + textWidth(title, font: commandFont) + optionCheckRoom
            case let .choice(choice): choiceTextInset + choiceWidth(choice)
            case .divider: 0
            }
        }.max() ?? 0
        let onlyOptions = entries.allSatisfy { entry in
            switch entry {
            case .option, .header, .divider: true
            case .command, .choice: false
            }
        }
        return min(max(widest.rounded(.up) + textInset, onlyOptions ? minimumOptionsWidth : minimumWidth), maximumWidth)
    }

    /// How wide a choice's text and count are.
    private static func choiceWidth(_ choice: RefMenu.Choice) -> Double {
        let text = max(textWidth(choice.title, font: titleFont), textWidth(choice.detailText, font: detailFont))
        return text + (choice.count.map { countGap + countWidth($0) } ?? 0)
    }

    static func countWidth(_ count: RefMenu.Count) -> Double {
        textWidth(count.text, font: countFont) + (count.icon == nil ? 0 : countIconSize + countIconGap)
    }

    static let countIconSize = 13.0

    static func textWidth(_ text: String, font: NSFont) -> Double {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    static func lineHeight(_ font: NSFont) -> Double {
        ceil(font.ascender - font.descender + font.leading)
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

extension RefMenu {
    /// The highlighted row, when `event` is the key that chooses it: Return, or
    /// Enter on the number pad.
    static func itemToChoose(after event: NSEvent, highlighted item: NSMenuItem?) -> NSMenuItem? {
        guard event.type == .keyDown, [36, 76].contains(event.keyCode),
              let item, item.isEnabled, item.representedObject is Command
        else { return nil }
        return item
    }

    /// How wide a choice's two lines can be, in a row `width` wide: past its
    /// checkmark and icon, and before its count.
    static func textRoom(inRow width: Double, count: Count?) -> Double {
        let count = count.map { Metrics.countWidth($0) + Metrics.countGap } ?? 0
        return max(0, width - Metrics.textInset - count - Metrics.choiceTextInset)
    }

    /// How wide a part of a choice's second line is, whole.
    static func detailWidth(_ text: String) -> Double {
        ceil(Metrics.textWidth(text, font: Metrics.detailFont))
    }

    /// How wide each part of a choice's second line is drawn in `room`, when
    /// some of them have to be cut short, or nil when the line is drawn as it
    /// always has been.
    static func detailWidths(of details: [Detail], in room: Double) -> [Double]? {
        detailWidths(
            of: details.map { (width: detailWidth($0.text), canBeCutShort: $0.canBeCutShort) },
            separator: detailWidth(Metrics.separator),
            in: room
        )
    }

    /// The parts before the last are whole, and the last, such as a folder,
    /// gets what's left, as long as they leave it room to show its name. When
    /// they don't, every part that can't be cut short stays whole, the last
    /// keeps that room, and the parts that can be cut share what's left by
    /// their widths, each cut at its end. They keep a few characters even when
    /// that takes some of the last part's room. A line with no part that can
    /// be cut, or one where the parts that can't leave no room even for that,
    /// is nil, and drawn as it always has been.
    static func detailWidths(of parts: [(width: Double, canBeCutShort: Bool)], separator: Double, in room: Double) -> [Double]? {
        guard let last = parts.last else { return nil }
        let lead = parts.dropLast()
        guard lead.contains(where: \.canBeCutShort) else { return nil }
        let separators = separator * Double(lead.count)
        let folder = min(last.width, Metrics.foldersRoom)
        guard lead.map(\.width).reduce(0, +) + separators + folder > room else { return nil }
        let whole = lead.filter { !$0.canBeCutShort }.map(\.width).reduce(0, +) + separators
        let cut = lead.filter(\.canBeCutShort)
        let least = Double(cut.count) * Metrics.leastOfACutPart
        guard whole + least <= room else { return nil }
        let left = max(room - whole - folder, least)
        let wanted = cut.map(\.width).reduce(0, +)
        var widths = lead.map { part in
            guard part.canBeCutShort, left < wanted else { return part.width }
            return floor(part.width * left / wanted)
        }
        widths.append(max(0, room - widths.reduce(0, +) - separators))
        return widths
    }
}

/// What a menu item calls when it's chosen.
final class Command: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run(_ sender: NSMenuItem) {
        action()
    }
}

/// The fill under a highlighted row, and choosing it with a click.
private class MenuRowView: NSView {
    /// How long after the menu opens a release still belongs to the click that
    /// opened it. Near the bottom of the screen the menu opens with its last row
    /// under the pointer, and that row can be the one that deletes.
    private static let openingClickDuration = 0.25

    private var openedAt = 0.0

    init(size: NSSize) {
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

    // macOS ignores Return while a row that draws itself is highlighted. The menu
    // hands the keys to the row it's highlighting when that row's view takes
    // them, so a row chooses itself on Return and passes on every other key. As
    // the menu opens it also hands them to the first row that takes them, and
    // highlights it, so no row takes them until the menu has opened.
    override var acceptsFirstResponder: Bool {
        ProcessInfo.processInfo.systemUptime - openedAt > Self.openingDuration
    }

    /// How long a menu takes to open.
    private static let openingDuration = 0.1

    override func keyDown(with event: NSEvent) {
        guard let menu = enclosingMenuItem?.menu,
              let item = RefMenu.itemToChoose(after: event, highlighted: menu.highlightedItem)
        else {
            super.keyDown(with: event)
            return
        }
        menu.cancelTracking()
        // Once the menu has closed, as after a click.
        DispatchQueue.main.async {
            let index = menu.index(of: item)
            if index >= 0 { menu.performActionForItem(at: index) }
        }
    }

    func drawHighlight() {
        guard let item = enclosingMenuItem, item.isHighlighted, item.isEnabled else { return }
        Colors.highlight.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: Metrics.highlightInset, dy: 0),
            xRadius: Metrics.highlightRadius,
            yRadius: Metrics.highlightRadius
        ).fill()
    }

    func drawSymbol(_ image: NSImage, size: Double, weight: NSFont.Weight, color: NSColor, centeredAt center: NSPoint) {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let symbol = image.withSymbolConfiguration(configuration) ?? image
        let rect = NSRect(
            x: (center.x - symbol.size.width / 2).rounded(),
            y: (center.y - symbol.size.height / 2).rounded(),
            width: symbol.size.width,
            height: symbol.size.height
        )
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    static let checkmark = Icon.check.nsImage ?? NSImage()

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
              let item = enclosingMenuItem, item.isEnabled, let menu = item.menu
        else { return }
        menu.cancelTracking()
        menu.performActionForItem(at: menu.index(of: item))
    }
}

/// A row's text, and the fill under it while it's highlighted. An option that's
/// chosen has a checkmark at the right, where its text would end.
private final class RowView: MenuRowView {
    private let title: String
    private let inset: Double
    private let isChecked: Bool
    private let attributes: [NSAttributedString.Key: Any]

    init(title: String, font: NSFont, color: NSColor, inset: Double, size: NSSize, isChecked: Bool = false) {
        self.title = title
        self.inset = inset
        self.isChecked = isChecked
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        attributes = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        super.init(size: size)
    }

    required init?(coder: NSCoder) {
        fatalError("The rows are made in code.")
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHighlight()
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(
            in: NSRect(
                x: inset,
                y: (bounds.height - height) / 2,
                width: bounds.width - inset - Metrics.textInset - (isChecked ? Metrics.optionCheckRoom : 0),
                height: height
            ),
            withAttributes: attributes
        )
        if isChecked {
            drawSymbol(Self.checkmark, size: 15, weight: .regular, color: Colors.command, centeredAt: NSPoint(x: bounds.width - Metrics.optionCheckCenter, y: bounds.midY))
        }
    }
}

/// A choice's two lines, with a checkmark when it's the current one, its icon,
/// and its count.
private final class ChoiceView: MenuRowView {
    private let choice: RefMenu.Choice

    init(choice: RefMenu.Choice, size: NSSize) {
        self.choice = choice
        super.init(size: size)
        toolTip = choice.help
    }

    required init?(coder: NSCoder) {
        fatalError("The rows are made in code.")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        drawHighlight()
        let middle = bounds.midY
        if choice.isCurrent {
            drawSymbol(Self.checkmark, size: 11, weight: .semibold, color: Colors.command, centeredAt: NSPoint(x: Metrics.checkCenter, y: middle))
        }
        if let icon = choice.icon {
            let color = choice.isEnabled ? Colors.header : Colors.disabled
            drawSymbol(icon, size: 14, weight: .regular, color: color, centeredAt: NSPoint(x: Metrics.iconCenter, y: middle))
        }

        if let count = choice.count {
            let width = Metrics.countWidth(count)
            drawCount(count, in: NSRect(x: bounds.width - Metrics.textInset - width, y: 0, width: width, height: bounds.height))
        }

        let titleHeight = Metrics.lineHeight(Metrics.titleFont)
        let detailHeight = Metrics.lineHeight(Metrics.detailFont)
        let top = ((bounds.height - titleHeight - Metrics.lineGap - detailHeight) / 2).rounded()
        let width = RefMenu.textRoom(inRow: bounds.width, count: choice.count)
        (choice.title as NSString).draw(
            in: NSRect(x: Metrics.choiceTextInset, y: top, width: width, height: titleHeight),
            withAttributes: Self.attributes(font: Metrics.titleFont, color: choice.isEnabled ? Colors.command : Colors.disabled)
        )
        drawDetails(in: NSRect(x: Metrics.choiceTextInset, y: top + titleHeight + Metrics.lineGap, width: width, height: detailHeight))
    }

    /// The second line, with each part in its own color. Its last part, such as
    /// a folder, is cut short, in its middle, so that what's going on stays whole
    /// and the folder keeps its name. When what's going on is too long to leave
    /// the folder that, only the parts that can be cut short, such as what an
    /// agent says it's doing, get shorter, at their end, and the rest, such as
    /// a worktree's conflicts and how long the agent has been at it, stay whole
    /// (`RefMenu.detailWidths(of:in:)`).
    private func drawDetails(in rect: NSRect) {
        guard let last = choice.details.last else { return }
        if let widths = RefMenu.detailWidths(of: choice.details, in: rect.width) {
            drawDetails(in: rect, widths: widths)
            return
        }
        let lead = details(choice.details.dropLast(), separatorAfter: true, lineBreak: .byTruncatingTail)
        let leadWidth = ceil(lead.size().width)
        guard leadWidth < rect.width else {
            lead.draw(in: rect)
            return
        }
        lead.draw(in: NSRect(x: rect.minX, y: rect.minY, width: leadWidth, height: rect.height))
        details([last], separatorAfter: false, lineBreak: .byTruncatingMiddle)
            .draw(in: NSRect(x: rect.minX + leadWidth, y: rect.minY, width: rect.width - leadWidth, height: rect.height))
    }

    /// Each part in its own width, the last cut in its middle and the others
    /// that can be cut short, at their end.
    private func drawDetails(in rect: NSRect, widths: [Double]) {
        let dim = choice.isEnabled ? Colors.header : Colors.disabled
        let separator = NSAttributedString(string: Metrics.separator, attributes: Self.attributes(font: Metrics.detailFont, color: dim, lineBreak: .byClipping))
        let separatorWidth = RefMenu.detailWidth(Metrics.separator)
        var x = rect.minX
        for (index, (detail, width)) in zip(choice.details, widths).enumerated() {
            let isLast = index == choice.details.count - 1
            details([detail], separatorAfter: false, lineBreak: isLast ? .byTruncatingMiddle : .byTruncatingTail)
                .draw(in: NSRect(x: x, y: rect.minY, width: width, height: rect.height))
            x += width
            guard !isLast else { break }
            separator.draw(in: NSRect(x: x, y: rect.minY, width: separatorWidth, height: rect.height))
            x += separatorWidth
        }
    }

    private func details(_ parts: some Collection<RefMenu.Detail>, separatorAfter: Bool, lineBreak: NSLineBreakMode) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let dim = choice.isEnabled ? Colors.header : Colors.disabled
        for (index, detail) in parts.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: Metrics.separator, attributes: Self.attributes(font: Metrics.detailFont, color: dim, lineBreak: lineBreak))) }
            let color = choice.isEnabled ? detail.color ?? dim : dim
            text.append(NSAttributedString(string: detail.text, attributes: Self.attributes(font: Metrics.detailFont, color: color, lineBreak: lineBreak)))
        }
        if separatorAfter, !parts.isEmpty {
            text.append(NSAttributedString(string: Metrics.separator, attributes: Self.attributes(font: Metrics.detailFont, color: dim, lineBreak: lineBreak)))
        }
        return text
    }

    private func drawCount(_ count: RefMenu.Count, in rect: NSRect) {
        var x = rect.minX
        if let icon = count.icon {
            let size = Metrics.countIconSize
            drawSymbol(icon, size: size - 1, weight: .medium, color: count.color, centeredAt: NSPoint(x: x + size / 2, y: rect.midY))
            x += size + Metrics.countIconGap
        }
        let attributes = Self.attributes(font: Metrics.countFont, color: count.color)
        let height = (count.text as NSString).size(withAttributes: attributes).height
        (count.text as NSString).draw(at: NSPoint(x: x, y: rect.midY - height / 2), withAttributes: attributes)
    }

    private static func attributes(font: NSFont, color: NSColor, lineBreak: NSLineBreakMode = .byTruncatingMiddle) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreak
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    // VoiceOver reads the row as its title and its second line.
    override func accessibilityLabel() -> String? {
        [choice.title, choice.detailText].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
