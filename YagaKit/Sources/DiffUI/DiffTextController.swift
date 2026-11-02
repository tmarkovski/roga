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
    /// How tall the find bar is while it's open, which is 0 when it's closed.
    /// The bar floats over the text, so the text starts this much lower. The
    /// first rows would otherwise stay hidden for as long as it's open.
    private var findBarHeight: CGFloat = 0 {
        didSet {
            guard findBarHeight != oldValue else { return }
            let clipView = scrollView.contentView
            let isAtTop = clipView.bounds.minY <= 0
            textView.textContainerInset.height = Self.inset + findBarHeight
            textView.sizeToFit()
            updateTextSize()
            // What's in view stays where it is, unless that's the top.
            if !isAtTop {
                clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: clipView.bounds.minY + findBarHeight - oldValue))
                scrollView.reflectScrolledClipView(clipView)
            }
            gutter.needsDisplay = true
        }
    }

    override public init() {
        // Made this way, it uses TextKit 1, and it doesn't own its text system.
        // One that does would take the text with it when it went away, which a
        // later text view might be showing.
        textView = DiffTextView(frame: .zero, textContainer: nil)
        let scrollView = DiffScrollView()
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
        scrollView.findBarHeightChanged = { [weak self] in self?.findBarHeight = $0 }
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
    public func show(_ document: DiffDocument) {
        guard document !== self.document else { return }
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
        // The find bar reads the text once, and nothing tells it when a text
        // view goes on to another document. This makes it read the text again.
        textView.usesFindBar = false
        textView.usesFindBar = true
        textView.sizeToFit()
        updateTextSize()
        textView.needsDisplay = true
        textView.scroll(NSPoint(x: 0, y: 0))
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
        textView.textContainerInset = NSSize(width: 0, height: Self.inset + findBarHeight)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
    }

    /// Shows the find bar, and puts the keyboard in it.
    public func showFind() {
        textView.window?.makeFirstResponder(textView)
        let action = NSMenuItem()
        action.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(action)
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

/// Says when the find bar opens and closes.
private final class DiffScrollView: NSScrollView {
    var findBarHeightChanged: ((CGFloat) -> Void)?

    override var isFindBarVisible: Bool {
        didSet { findBarHeightChanged?(isFindBarVisible ? findBarView?.frame.height ?? 0 : 0) }
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
