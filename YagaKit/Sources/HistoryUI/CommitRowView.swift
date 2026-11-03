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
            if content != oldValue { needsDisplay = true }
        }
    }

    /// How many columns of the graph to show, which is the same in every
    /// row.
    var graphColumns = 0 {
        didSet {
            if graphColumns != oldValue { needsDisplay = true }
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

    override func draw(_ dirtyRect: NSRect) {
        guard let content else { return }
        let layout = CommitRowLayout(content: content, graphColumns: graphColumns, size: bounds.size)
        if graphColumns > 0, let lanes = content.lanes {
            LaneRenderer.draw(lanes, columns: graphColumns, at: CommitRowLayout.graphX, height: bounds.height, isHollow: content.isWorkingTree)
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
            draw(subject, at: layout.subjectX, width: layout.subjectMaxX - layout.subjectX, style: Style.subject)
        }
    }

    private func draw(_ text: String, at x: CGFloat, width: CGFloat, style: Style) {
        let rect = NSRect(x: x, y: ((bounds.height - style.lineHeight) / 2).rounded(), width: width, height: style.lineHeight)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: style.attributes)
    }

    private func drawBadge(_ badge: CommitRowContent.Badge, in rect: NSRect, isHovered: Bool) {
        let color = Self.color(for: badge.kind)
        let style = Style.badge(color)
        let padding = CommitRowLayout.badgePadding

        color.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        if isHovered {
            color.withAlphaComponent(0.75).setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5).stroke()
        }
        var textX = rect.minX + padding
        if let icon = Self.icon(for: badge.kind) {
            let iconRect = NSRect(
                x: textX, y: rect.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height
            )
            icon.draw(in: iconRect.integral, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            textX += icon.size.width + CommitRowLayout.badgeIconGap
        }
        draw(badge.title, at: textX, width: max(0, rect.maxX - padding - textX), style: style)
    }

    fileprivate static func color(for kind: CommitRowContent.Badge.Kind) -> NSColor {
        switch kind {
        case .currentBranch, .detachedHead: .systemGreen
        case .branch: .systemBlue
        case .remoteBranch: .systemPurple
        case .tag: .systemOrange
        }
    }

    fileprivate static func icon(for kind: CommitRowContent.Badge.Kind) -> NSImage? {
        let symbol: (name: String, size: CGFloat, weight: NSFont.Weight)
        switch kind {
        case .currentBranch: symbol = ("checkmark", 8, .bold)
        case .tag: symbol = ("tag", 8.5, .regular)
        case .detachedHead, .branch, .remoteBranch: return nil
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: symbol.size, weight: symbol.weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color(for: kind)]))
        return NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
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
        static let detail = Style(font: .systemFont(ofSize: 12.5), color: .secondaryLabelColor)
        static let shortID = Style(font: .monospacedSystemFont(ofSize: 11.5, weight: .regular), color: .tertiaryLabelColor)

        static func badge(_ color: NSColor) -> Style {
            Style(font: .systemFont(ofSize: 11, weight: .medium), color: color)
        }
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
        let style = CommitCellView.Style.badge(CommitCellView.color(for: badge.kind))
        let iconWidth = CommitCellView.icon(for: badge.kind).map { $0.size.width + badgeIconGap } ?? 0
        let titleWidth = ceil((badge.title as NSString).size(withAttributes: style.attributes).width)
        return badgePadding + iconWidth + titleWidth + badgePadding
    }
}
