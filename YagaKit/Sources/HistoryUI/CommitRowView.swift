import AppKit

/// A row of the commit list. It draws the selection as a soft gray rounded
/// rectangle rather than in the accent color, which is kept for the graph.
final class CommitRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("CommitRowView")

    static let selectionColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(white: isDark ? 0.245 : 0.91, alpha: 1)
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) {
        fatalError("Rows are made in code.")
    }

    override func drawSelection(in dirtyRect: NSRect) {
        Self.selectionColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 7, yRadius: 7).fill()
    }
}

/// The contents of a row: the graph, badges for refs and the subject on the
/// left, then the author, the date and the short ID in columns on the right. It draws the
/// text itself instead of using text fields, which keeps scrolling fast.
final class CommitCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("CommitCellView")
    static let height: CGFloat = 28

    var content: CommitRowContent? {
        didSet {
            if content != oldValue {
                needsDisplay = true
                updateToolTips()
            }
        }
    }

    /// How many columns of the graph to show, which is the same in every
    /// row.
    var graphColumns = 0 {
        didSet {
            if graphColumns != oldValue {
                needsDisplay = true
                updateToolTips()
            }
        }
    }

    /// The index of the badge the pointer is over, which has a border.
    var hoveredBadge: Int? {
        didSet {
            if hoveredBadge != oldValue { needsDisplay = true }
        }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) {
        fatalError("Rows are made in code.")
    }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateToolTips()
    }

    /// Where the badges with tooltips are.
    private var toolTipFrames: [NSRect] = []

    /// Gives each badge a tooltip, since it's drawn rather than being a view.
    private func updateToolTips() {
        var frames: [NSRect] = []
        if let content, !content.badges.isEmpty {
            frames = CommitRowLayout(content: content, graphColumns: graphColumns, size: bounds.size).badges
        }
        guard frames != toolTipFrames else { return }
        toolTipFrames = frames
        removeAllToolTips()
        for frame in frames { addToolTip(frame, owner: self, userData: nil) }
    }

    /// The tint on a commit that a count in the title row would move, which is
    /// the brand's orange.
    private static let previewColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 240 / 255, green: 129 / 255, blue: 63 / 255, alpha: 0.16)
            : NSColor(srgbRed: 201 / 255, green: 68 / 255, blue: 2 / 255, alpha: 0.1)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let content else { return }
        if content.isPreviewed {
            Self.previewColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        let layout = CommitRowLayout(content: content, graphColumns: graphColumns, size: bounds.size)
        if graphColumns > 0, let lanes = content.lanes {
            LaneRenderer.draw(lanes, columns: graphColumns, at: CommitRowLayout.graphX, height: bounds.height, isHollow: content.isWorkingTree, isCurrent: content.isCurrent)
        }
        for column in layout.columns {
            if let text = column.text {
                draw(text, at: column.x, width: column.width, style: column.style)
            }
        }
        for (index, frame) in layout.badges.enumerated() {
            drawBadge(content.badges[index], in: frame, isHovered: index == hoveredBadge)
        }
        if let subject = content.subject, layout.subjectMaxX > layout.subjectX {
            let style = content.isCurrent ? Style.currentSubject : Style.subject
            draw(subject, at: layout.subjectX, width: layout.subjectMaxX - layout.subjectX, style: style)
            if let body = content.body, !body.isEmpty { drawBody(body, after: subject, in: style, layout: layout) }
        }
    }

    /// Draws the body in whatever room the subject leaves, if that's enough to
    /// be worth reading.
    private func drawBody(_ body: String, after subject: String, in subjectStyle: Style, layout: CommitRowLayout) {
        let subjectWidth = ceil((subject as NSString).size(withAttributes: subjectStyle.attributes).width)
        let x = layout.subjectX + subjectWidth + CommitRowLayout.bodyGap
        let width = layout.subjectMaxX - x
        guard width >= CommitRowLayout.minimumBodyWidth else { return }
        // Laying out text takes time in proportion to its length, so this leaves
        // out what can't fit, going by how narrow a line's characters can average.
        draw(String(body.prefix(Int(width / 5))), at: x, width: width, style: Style.detail)
    }

    private func draw(_ text: String, at x: CGFloat, width: CGFloat, style: Style) {
        let rect = NSRect(x: x, y: ((bounds.height - style.lineHeight) / 2).rounded(), width: width, height: style.lineHeight)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: style.attributes)
    }

    private func drawBadge(_ badge: CommitRowContent.Badge, in rect: NSRect, isHovered: Bool) {
        let look = BadgeLook.of(badge.kind)
        let padding = CommitRowLayout.badgePadding

        look.fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        (isHovered ? look.text : look.edge).setStroke()
        NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5).stroke()

        var textX = rect.minX + padding
        if let icon = Self.icon(for: badge.kind) {
            draw(icon, at: textX, in: rect)
            textX += icon.size.width + CommitRowLayout.badgeIconGap
        }
        // The name gives way when the badge is cut short, and what follows it stays.
        var textMaxX = rect.maxX - padding
        if badge.upstream != nil, let cloud = Self.cloud(for: badge.kind) {
            textMaxX -= cloud.size.width + CommitRowLayout.badgeIconGap
            draw(cloud, at: textMaxX + CommitRowLayout.badgeIconGap, in: rect)
        }
        let (name, remote) = badge.nameAndRemote
        if let remote {
            let width = CommitRowLayout.width(of: remote, in: look.remoteStyle)
            textMaxX -= width
            draw(remote, at: textMaxX, width: width, style: look.remoteStyle)
            textMaxX -= CommitRowLayout.badgeDividerGap + 1
            look.text.withAlphaComponent(0.5).setFill()
            NSRect(x: textMaxX.rounded(), y: rect.midY - 6, width: 1, height: 12).fill()
            textMaxX -= CommitRowLayout.badgeDividerGap
        }
        draw(name, at: textX, width: max(0, textMaxX - textX), style: look.style)
    }

    private func draw(_ icon: NSImage, at x: CGFloat, in rect: NSRect) {
        let iconRect = NSRect(x: x, y: rect.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height)
        icon.draw(in: iconRect.integral, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    fileprivate static func icon(for kind: CommitRowContent.Badge.Kind) -> NSImage? {
        switch kind {
        case .currentBranch: symbol("checkmark", size: 9, weight: .bold, for: kind)
        case .tag: symbol("tag", size: 8.5, weight: .regular, for: kind)
        case .detachedHead, .branch, .remoteBranch: nil
        }
    }

    /// The mark on a badge that stands for its upstream too.
    fileprivate static func cloud(for kind: CommitRowContent.Badge.Kind) -> NSImage? {
        symbol("cloud", size: 9.5, weight: .medium, for: kind)
    }

    private struct SymbolKey: Hashable {
        var name: String
        var kind: CommitRowContent.Badge.Kind
        var isDark: Bool
    }

    /// The symbols made so far. Making one takes a few hundred microseconds, far
    /// more than drawing it again, and a row needs each one to lay out and to draw.
    private static var symbols: [SymbolKey: NSImage] = [:]

    private static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, for kind: CommitRowContent.Badge.Kind) -> NSImage? {
        let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = SymbolKey(name: name, kind: kind, isDark: isDark)
        if let symbol = symbols[key] { return symbol }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [BadgeLook.of(kind).text]))
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        symbols[key] = symbol
        return symbol
    }

    // Each row reads as one piece of text to VoiceOver, since its text is
    // drawn rather than held in text fields.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { content?.spokenText }

    /// The font and color for each kind of text.
    struct Style {
        let attributes: [NSAttributedString.Key: Any]
        let lineHeight: CGFloat

        init(font: NSFont, color: NSColor) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            attributes = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            lineHeight = ceil(font.ascender - font.descender)
        }

        static let subject = Style(font: .systemFont(ofSize: 12.5), color: .labelColor)
        static let currentSubject = Style(font: .systemFont(ofSize: 12.5, weight: .semibold), color: .labelColor)
        static let detail = Style(font: .systemFont(ofSize: 12.5), color: .secondaryLabelColor)
        static let shortID = Style(font: .monospacedSystemFont(ofSize: 11.5, weight: .regular), color: .tertiaryLabelColor)

    }

    /// What a badge looks like. Its colors are opaque, so that it looks the same
    /// on a selected row. Only where you are is filled, which sets it apart by its
    /// shape, and the other colors say how much a ref is yours rather than what
    /// kind it is: its name and its icon already say that.
    struct BadgeLook {
        let fill: NSColor
        let edge: NSColor
        let text: NSColor
        let style: Style
        /// For the remote's name after a branch's.
        let remoteStyle: Style

        private init(fill: NSColor, edge: NSColor, text: NSColor, weight: NSFont.Weight = .medium) {
            self.fill = fill
            self.edge = edge
            self.text = text
            style = Style(font: .systemFont(ofSize: 11, weight: weight), color: text)
            remoteStyle = Style(font: .systemFont(ofSize: 11), color: text)
        }

        private static func color(light: Int, dark: Int) -> NSColor {
            func color(_ value: Int) -> NSColor {
                NSColor(
                    srgbRed: CGFloat(value >> 16 & 0xFF) / 255,
                    green: CGFloat(value >> 8 & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255,
                    alpha: 1
                )
            }
            let (light, dark) = (color(light), color(dark))
            return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
        }

        private static let green = color(light: 0x1A7F37, dark: 0x4AD66D)
        private static let plainFill = color(light: 0xFFFFFF, dark: 0x2A2A29)
        private static let plainEdge = color(light: 0xBDBDB8, dark: 0x62625C)

        private static let here = BadgeLook(fill: green, edge: green, text: color(light: 0xFFFFFF, dark: 0x06240F), weight: .bold)
        private static let yours = BadgeLook(fill: plainFill, edge: plainEdge, text: color(light: 0x123FA3, dark: 0xA5C0FF))
        private static let others = BadgeLook(fill: plainFill, edge: plainEdge, text: color(light: 0x55554F, dark: 0xC4C4BE))

        static func of(_ kind: CommitRowContent.Badge.Kind) -> BadgeLook {
            switch kind {
            case .currentBranch, .detachedHead: here
            case .branch: yours
            case .remoteBranch, .tag: others
            }
        }
    }
}

extension CommitCellView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let content, let index = toolTipFrames.firstIndex(where: { $0.contains(point) }), index < content.badges.count else { return "" }
        return content.badges[index].spokenTitle
    }
}

/// Where the parts of a row go, which drawing it and finding what the pointer
/// is over both need.
struct CommitRowLayout {
    struct Column {
        var text: String?
        var x: CGFloat
        var width: CGFloat
        var style: CommitCellView.Style
    }

    static let graphX = inset - LaneRenderer.spacing / 2
    static let badgePadding: CGFloat = 6
    static let badgeIconGap: CGFloat = 3
    /// The space on each side of the line between a branch's name and its remote's.
    static let badgeDividerGap: CGFloat = 4
    /// The space between the subject and the body.
    static let bodyGap: CGFloat = 10
    /// Less room than this for the body isn't worth drawing.
    static let minimumBodyWidth: CGFloat = 60
    private static let inset: CGFloat = 14
    private static let gap: CGFloat = 10

    /// The columns on the right that fit.
    private(set) var columns: [Column] = []
    /// Where each badge goes, for as many of a row's badges as fit.
    private(set) var badges: [NSRect] = []
    private(set) var subjectX: CGFloat
    private(set) var subjectMaxX: CGFloat

    init(content: CommitRowContent, graphColumns: Int, size: NSSize) {
        var left = Self.inset
        var right = size.width - Self.inset

        // The graph starts so that its first column lines up with the text
        // in rows without one.
        if graphColumns > 0 {
            left = Self.graphX + LaneRenderer.width(columns: graphColumns) + 6
        }

        // The columns on the right give way, starting from the author, when
        // the row is too narrow for them and some of the subject.
        let columns: [(text: String?, width: CGFloat, style: CommitCellView.Style)] = [
            (content.shortID, 72, CommitCellView.Style.shortID),
            (content.date, 112, CommitCellView.Style.detail),
            (content.author, 130, CommitCellView.Style.detail),
        ]
        for column in columns {
            guard right - column.width - Self.gap >= left + 120 else { break }
            right -= column.width
            self.columns.append(Column(text: column.text, x: right, width: column.width, style: column.style))
            right -= Self.gap
        }

        for badge in content.badges {
            guard right - left > 40 else { break }
            let width = min(Self.badgeWidth(badge), right - left)
            let height: CGFloat = 18
            let frame = NSRect(x: left, y: ((size.height - height) / 2).rounded(), width: width, height: height)
            badges.append(frame)
            left = frame.maxX + 5
        }
        subjectX = left
        subjectMaxX = right
    }

    private static func badgeWidth(_ badge: CommitRowContent.Badge) -> CGFloat {
        let look = CommitCellView.BadgeLook.of(badge.kind)
        let (name, remote) = badge.nameAndRemote
        let iconWidth = CommitCellView.icon(for: badge.kind).map { $0.size.width + badgeIconGap } ?? 0
        let cloudWidth = badge.upstream == nil ? 0 : CommitCellView.cloud(for: badge.kind).map { $0.size.width + badgeIconGap } ?? 0
        let remoteWidth = remote.map { badgeDividerGap + 1 + badgeDividerGap + width(of: $0, in: look.remoteStyle) } ?? 0
        return badgePadding + iconWidth + width(of: name, in: look.style) + remoteWidth + cloudWidth + badgePadding
    }

    static func width(of text: String, in style: CommitCellView.Style) -> CGFloat {
        ceil((text as NSString).size(withAttributes: style.attributes).width)
    }
}
