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

/// The contents of a row: badges for refs and the subject on the left, then
/// the author, the date and the short ID in columns on the right. It draws the
/// text itself instead of using text fields, which keeps scrolling fast.
final class CommitCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("CommitCellView")
    static let height: CGFloat = 28

    var content: CommitRowContent? {
        didSet {
            if content != oldValue { needsDisplay = true }
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
        let inset: CGFloat = 14
        let gap: CGFloat = 10
        var left = inset
        var right = bounds.width - inset

        // The columns on the right give way, starting from the author, when
        // the row is too narrow for them and some of the subject.
        let columns: [(text: String?, width: CGFloat, style: Style)] = [
            (content.shortID, 72, Style.shortID),
            (content.date, 112, Style.detail),
            (content.author, 130, Style.detail),
        ]
        for column in columns {
            guard right - column.width - gap >= left + 120 else { break }
            right -= column.width
            if let text = column.text {
                draw(text, at: right, width: column.width, style: column.style)
            }
            right -= gap
        }

        for badge in content.badges {
            guard right - left > 40 else { break }
            left = drawBadge(badge, at: left, maxX: right) + 5
        }
        if let subject = content.subject, right > left {
            draw(subject, at: left, width: right - left, style: Style.subject)
        }
    }

    private func draw(_ text: String, at x: CGFloat, width: CGFloat, style: Style) {
        let rect = NSRect(x: x, y: ((bounds.height - style.lineHeight) / 2).rounded(), width: width, height: style.lineHeight)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: style.attributes)
    }

    /// Draws a badge and returns where it ends.
    private func drawBadge(_ badge: CommitRowContent.Badge, at x: CGFloat, maxX: CGFloat) -> CGFloat {
        let color = Self.color(for: badge.kind)
        let style = Style.badge(color)
        let icon = Self.icon(for: badge.kind, color: color)
        let padding: CGFloat = 6
        let iconWidth = icon.map { $0.size.width + 3 } ?? 0
        let titleWidth = ceil((badge.title as NSString).size(withAttributes: style.attributes).width)
        let width = min(padding + iconWidth + titleWidth + padding, maxX - x)
        let badgeHeight: CGFloat = 18
        let rect = NSRect(x: x, y: ((bounds.height - badgeHeight) / 2).rounded(), width: width, height: badgeHeight)

        color.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        var textX = rect.minX + padding
        if let icon {
            let iconRect = NSRect(
                x: textX, y: rect.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height
            )
            icon.draw(in: iconRect.integral, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            textX += iconWidth
        }
        draw(badge.title, at: textX, width: max(0, rect.maxX - padding - textX), style: style)
        return rect.maxX
    }

    private static func color(for kind: CommitRowContent.Badge.Kind) -> NSColor {
        switch kind {
        case .currentBranch, .detachedHead: .systemGreen
        case .branch: .systemBlue
        case .remoteBranch: .systemPurple
        case .tag: .systemOrange
        }
    }

    private static func icon(for kind: CommitRowContent.Badge.Kind, color: NSColor) -> NSImage? {
        let symbol: (name: String, size: CGFloat, weight: NSFont.Weight)
        switch kind {
        case .currentBranch: symbol = ("checkmark", 8, .bold)
        case .tag: symbol = ("tag", 8.5, .regular)
        case .detachedHead, .branch, .remoteBranch: return nil
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: symbol.size, weight: symbol.weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
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
