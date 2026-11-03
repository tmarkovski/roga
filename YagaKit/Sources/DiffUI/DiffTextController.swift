import AppKit

/// Owns the text view that shows one file's patch, and the line numbers beside
/// it. It uses TextKit 1 with non-contiguous layout, which lays out only the
/// lines in view, and doesn't wrap lines (decision 9).
public final class DiffTextController: NSObject {
    /// The line numbers and the text.
    public let view: NSView
    public let scrollView: NSScrollView
    private let textView: DiffTextView
    private let gutter: LineNumberGutter
    public private(set) var document: DiffDocument?

    /// The space above and below the text.
    private static let inset: CGFloat = 4

    override public init() {
        // Made this way, it uses TextKit 1, and it doesn't own its text system.
        // One that does would take the text with it when it went away, which a
        // later text view might be showing.
        textView = DiffTextView(frame: .zero, textContainer: nil)
        let scrollView = NSScrollView()
        self.scrollView = scrollView
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalLineScroll = DiffStyle.lineHeight
        scrollView.horizontalLineScroll = DiffStyle.columnWidth * 4

        gutter = LineNumberGutter(textView: textView)
        view = SideBySideView(gutter: gutter, scrollView: scrollView)

        super.init()

        configureTextView()
        let clipView = scrollView.contentView
        clipView.postsFrameChangedNotifications = true
        clipView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clipViewChangedSize), name: NSView.frameDidChangeNotification, object: clipView)
        center.addObserver(self, selector: #selector(clipViewScrolled), name: NSView.boundsDidChangeNotification, object: clipView)
    }

    @objc private func clipViewChangedSize() {
        updateTextSize()
    }

    /// The gutter doesn't move with the text, so it draws again.
    @objc private func clipViewScrolled() {
        gutter.needsDisplay = true
    }

    isolated deinit {
        letGoOfDocument()
    }

    /// Shows a patch from its start.
    ///
    /// - Parameter keepingPosition: Whether the text stays scrolled to the same
    ///   place, for a newer copy of the document showing.
    public func show(_ document: DiffDocument, keepingPosition: Bool = false) {
        guard document !== self.document else { return }
        let position = scrollView.contentView.bounds.origin
        // The selection is a place in the old text, which the new one may not have.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        letGoOfDocument()
        self.document = document
        gutter.document = document
        view.needsLayout = true
        // An earlier view may still have this document, when a window goes to
        // another worktree and back.
        document.container.textView?.textContainer = nil
        document.container.textView = textView
        configureTextView()
        textView.sizeToFit()
        updateTextSize()
        textView.needsDisplay = true
        textView.scroll(keepingPosition ? position : NSPoint(x: 0, y: 0))
    }

    /// A text view that's going away takes its text container with it, so it
    /// has to give up one that another text view may go on to show. The text
    /// view and the container each keep a pointer to the other.
    private func letGoOfDocument() {
        guard let container = document?.container, container.textView === textView else { return }
        textView.textContainer = nil
        container.textView = nil
    }

    /// TextKit keeps most of a text view's settings with its layout manager, so
    /// they need setting for each document.
    private func configureTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        // Copying gives plain text rather than colored text.
        textView.isRichText = false
        textView.usesRuler = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: Self.inset)
    }

    /// Marks where the text being searched for shows in the document showing,
    /// and which match the search is at.
    public func showMatches(_ matches: [NSRange], current: Int?) {
        guard let layoutManager = document?.layoutManager,
              matches != layoutManager.matches || current != layoutManager.currentMatch else { return }
        layoutManager.matches = matches
        layoutManager.currentMatch = current
        textView.needsDisplay = true
    }

    /// Brings the match the search is at into view, with some of what's around it.
    public func scrollToCurrentMatch() {
        guard let document, let match = currentMatch else { return }
        let glyphs = document.layoutManager.glyphRange(forCharacterRange: match, actualCharacterRange: nil)
        let origin = textView.textContainerOrigin
        let rect = document.layoutManager.boundingRect(forGlyphRange: glyphs, in: document.container)
            .offsetBy(dx: origin.x, dy: origin.y)
        textView.scrollToVisible(rect.insetBy(dx: -DiffStyle.columnWidth * 8, dy: -DiffStyle.lineHeight * 3))
    }

    /// Selects the match the search is at, and gives the text the keyboard,
    /// for when the search closes.
    public func endFind() {
        if let currentMatch { textView.setSelectedRange(currentMatch) }
        textView.window?.makeFirstResponder(textView)
    }

    private var currentMatch: NSRange? {
        guard let layoutManager = document?.layoutManager, let current = layoutManager.currentMatch else { return nil }
        return layoutManager.matches[current]
    }

    /// Makes the text as wide as its longest line, or as the view if that's
    /// wider, since the lines' backgrounds fill it.
    private func updateTextSize() {
        let visible = scrollView.contentSize
        let width = CGFloat(document?.columns ?? 0) * DiffStyle.columnWidth + DiffStyle.textPadding * 2
        textView.minSize = NSSize(width: 0, height: visible.height)
        textView.setFrameSize(NSSize(width: max(width, visible.width), height: max(textView.frame.height, visible.height)))
    }
}

/// Puts the gutter on the left and the text in the rest.
private final class SideBySideView: NSView {
    private let gutter: LineNumberGutter
    private let scrollView: NSScrollView

    init(gutter: LineNumberGutter, scrollView: NSScrollView) {
        self.gutter = gutter
        self.scrollView = scrollView
        super.init(frame: .zero)
        addSubview(gutter)
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("This view isn't loaded from files")
    }

    override func layout() {
        super.layout()
        let thickness = gutter.thickness
        gutter.frame = NSRect(x: 0, y: 0, width: thickness, height: bounds.height)
        scrollView.frame = NSRect(x: thickness, y: 0, width: max(0, bounds.width - thickness), height: bounds.height)
    }
}
