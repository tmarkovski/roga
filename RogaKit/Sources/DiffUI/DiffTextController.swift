import AppKit
import GitCore

/// Owns the text view that shows one file's patch, and the line numbers beside
/// it. It uses TextKit 1 with non-contiguous layout, which lays out only the
/// lines in view, and doesn't wrap lines (decision 9).
public final class DiffTextController: NSObject {
    /// The line numbers and the text.
    public let view: NSView
    public let scrollView: NSScrollView
    private let textView: DiffTextView
    private let gutter: LineNumberGutter
    private let sides: SideBySideView
    let hunkButton = HunkButton()
    public private(set) var document: DiffDocument?

    /// Takes a hunk out of the file, by the index of its header among the patch's
    /// lines, or nil when the hunks showing can't be taken out (decision 39).
    public var discardHunk: ((Int) -> Void)? {
        didSet { updateHunkButton() }
    }

    /// Resolves one of a file's conflicts, or puts one back, or nil when the
    /// document showing has none to resolve (decision 60).
    public var resolveConflict: ((ConflictRequest) -> Void)? {
        didSet { updateConflictBars() }
    }

    /// Makes what goes around each unresolved conflict in view, while an agent is
    /// working on them, or nil while none is (decision 65). The view that's made
    /// shouldn't take clicks, since it sits over the conflict's buttons.
    public var makeConflictOutline: (() -> NSView)? {
        didSet {
            conflictOutlines.forEach { $0.removeFromSuperview() }
            conflictOutlines = []
            updateConflictOutlines()
        }
    }

    /// The bars on the conflicts' bands in view, and spare ones, which stay
    /// rather than being made again as the text scrolls.
    private var conflictBars: [ConflictBar] = []
    /// What's around the unresolved conflicts in view, and spare ones.
    private var conflictOutlines: [NSView] = []
    /// Where someone is writing the lines that resolve a conflict.
    private var editor: NSPopover?

    /// The space above and below the text.
    private static let inset: CGFloat = 4
    /// How far a conflict's outline stays from the view's sides, so that the
    /// light's glow isn't cut off along them.
    static let outlineInset: CGFloat = 2

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
        sides = SideBySideView(gutter: gutter, scrollView: scrollView, hunkButton: hunkButton)
        view = sides

        super.init()

        hunkButton.target = self
        hunkButton.action = #selector(hunkButtonPressed)
        sides.pointerChanged = { [weak self] in self?.updateHunkButton() }
        textView.menuItem = { [weak self] point in self?.hunkMenuItem(atTextY: point.y) }

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
        updateHunkButton()
        updateConflictBars()
    }

    /// The gutter doesn't move with the text, so it draws again.
    @objc private func clipViewScrolled() {
        gutter.needsDisplay = true
        updateHunkButton()
        updateConflictBars()
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
        updateHunkButton()
        editor?.close()
        updateConflictBars()
    }

    /// A text view that's going away takes its text container with it, so it
    /// has to give up one that another text view may go on to show. The text
    /// view and the container each keep a pointer to the other.
    private func letGoOfDocument() {
        guard let container = document?.container, container.textView === textView else { return }
        textView.textContainer = nil
        container.textView = nil
    }

    // MARK: Hunks

    /// The header of the hunk at a height in the text view. Every line is one row of
    /// the same height, so this takes no layout, however long the patch is.
    func hunkHeader(atTextY y: CGFloat) -> Int? {
        let row = ((y - textView.textContainerOrigin.y) / DiffStyle.lineHeight).rounded(.down)
        return document?.hunkHeader(atRow: Int(row))
    }

    /// Shows the button for the hunk under the pointer, on its band, and at the edge
    /// of the view, so that it stays put as the text scrolls sideways.
    private func updateHunkButton() {
        guard sides.isPointerInside, let window = view.window else {
            hunkButton.isHidden = true
            return
        }
        showHunkButton(atTextY: textView.convert(window.mouseLocationOutsideOfEventStream, from: nil).y)
    }

    /// Shows the button for the hunk at a height in the text view, if it can be
    /// discarded and its band is in view.
    func showHunkButton(atTextY y: CGFloat) {
        guard discardHunk != nil, let header = hunkHeader(atTextY: y) else {
            hunkButton.isHidden = true
            return
        }
        let top = textView.textContainerOrigin.y + CGFloat(header) * DiffStyle.lineHeight
        let band = view.convert(NSRect(x: 0, y: top, width: 1, height: DiffStyle.lineHeight), from: textView)
        let clip = scrollView.contentView
        let visible = view.convert(clip.bounds, from: clip)
        guard visible.minY...visible.maxY ~= band.midY else {
            hunkButton.isHidden = true
            return
        }
        let size = hunkButton.size
        hunkButton.frame = NSRect(x: visible.maxX - size.width - 6, y: (band.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        hunkButton.header = header
        hunkButton.isHidden = false
    }

    @objc private func hunkButtonPressed() {
        // The next hunk moves up under the pointer, and that's not what a double-click
        // meant to take.
        guard NSApp?.currentEvent?.isRepeatedClick != true, let header = hunkButton.header else { return }
        discardHunk?(header)
    }

    /// What right-clicking a hunk offers, if it can be discarded.
    func hunkMenuItem(atTextY y: CGFloat) -> NSMenuItem? {
        guard discardHunk != nil, let header = hunkHeader(atTextY: y) else { return nil }
        let item = NSMenuItem(title: "Discard Hunk", action: #selector(hunkMenuItemChosen), keyEquivalent: "")
        item.target = self
        item.representedObject = header
        return item
    }

    @objc private func hunkMenuItemChosen(_ item: NSMenuItem) {
        guard let header = item.representedObject as? Int else { return }
        discardHunk?(header)
    }

    // MARK: Conflicts

    /// Puts a bar on each conflict's band in view, at the edge of the view, so that
    /// the buttons stay put as the text scrolls sideways.
    func updateConflictBars() {
        updateConflictOutlines()
        guard let document, let conflicts = document.conflicts, resolveConflict != nil, !document.conflictBands.isEmpty else {
            conflictBars.forEach { $0.isHidden = true }
            return
        }
        let clip = scrollView.contentView
        let visible = view.convert(clip.bounds, from: clip)
        let origin = textView.textContainerOrigin.y
        let shown = textView.visibleRect
        let firstRow = Int(((shown.minY - origin) / DiffStyle.lineHeight).rounded(.down))
        let lastRow = Int(((shown.maxY - origin) / DiffStyle.lineHeight).rounded(.up))
        let bands = document.conflictBands.filter { $0.row >= firstRow && $0.row <= lastRow }
        let count = document.conflictBands.count
        while conflictBars.count < bands.count {
            let bar = ConflictBar()
            bar.onAction = { [weak self] bar, action, button in self?.conflictAction(action, of: bar, from: button) }
            sides.addSubview(bar)
            conflictBars.append(bar)
        }
        for (index, bar) in conflictBars.enumerated() {
            guard index < bands.count else {
                bar.isHidden = true
                continue
            }
            let band = bands[index]
            bar.show(band, sides: conflicts.sides, of: count)
            let top = origin + CGFloat(band.row) * DiffStyle.lineHeight
            let row = view.convert(NSRect(x: 0, y: top, width: 1, height: DiffStyle.lineHeight), from: textView)
            let size = bar.size
            bar.frame = NSRect(x: visible.maxX - size.width - 6, y: (row.midY - size.height / 2).rounded(), width: size.width, height: size.height)
            bar.isHidden = !(visible.minY...visible.maxY ~= row.midY)
        }
    }

    /// Puts an outline around each unresolved conflict in view: the whole section,
    /// line numbers included, as wide as the view whichever way the text is
    /// scrolled sideways, and cut off where it runs past the view's top or bottom.
    private func updateConflictOutlines() {
        guard let make = makeConflictOutline, let document else {
            conflictOutlines.forEach { $0.isHidden = true }
            return
        }
        let origin = textView.textContainerOrigin.y
        let shown = textView.visibleRect
        let firstRow = Int(((shown.minY - origin) / DiffStyle.lineHeight).rounded(.down))
        let lastRow = Int(((shown.maxY - origin) / DiffStyle.lineHeight).rounded(.up))
        let blocks = document.unresolvedConflictRows.filter { $0.upperBound > firstRow && $0.lowerBound <= lastRow }
        while conflictOutlines.count < blocks.count {
            let outline = make()
            // Under the bars and the hunk's button, which it mustn't draw across.
            sides.addSubview(outline, positioned: .above, relativeTo: scrollView)
            conflictOutlines.append(outline)
        }
        for (index, outline) in conflictOutlines.enumerated() {
            guard index < blocks.count else {
                outline.isHidden = true
                continue
            }
            let rows = blocks[index]
            let block = view.convert(
                NSRect(x: 0, y: origin + CGFloat(rows.lowerBound) * DiffStyle.lineHeight, width: 1, height: CGFloat(rows.count) * DiffStyle.lineHeight),
                from: textView
            )
            outline.frame = NSRect(x: Self.outlineInset, y: block.minY, width: max(view.bounds.width - 2 * Self.outlineInset, 0), height: block.height)
            outline.isHidden = false
        }
    }

    private func conflictAction(_ action: ConflictBar.Action, of bar: ConflictBar, from button: NSButton) {
        switch action {
        case .keep(let choice): resolveConflict?(.choose(bar.conflict, choice))
        case .undo: resolveConflict?(.undo(bar.conflict))
        case .showSides(let shows): resolveConflict?(.showSides(bar.conflict, shows))
        case .edit: edit(bar.conflict, from: button)
        }
    }

    /// Opens a box for writing the lines that resolve a conflict, under its Edit…
    /// button, starting with both sides.
    private func edit(_ conflict: Int, from button: NSButton) {
        guard let document, let text = document.conflicts?.edits[conflict] else { return }
        editor?.close()
        let count = document.conflictBands.count
        let controller = ConflictEditor(heading: "Conflict \(conflict + 1) of \(count)", text: text)
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        controller.onFinish = { [weak self, weak popover] text in
            popover?.close()
            guard let self, let text, self.document === document else { return }
            self.resolveConflict?(.choose(conflict, .lines(ConflictedFile.lines(typed: text))))
        }
        editor = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
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

/// Puts the gutter on the left and the text in the rest, and the button for a hunk
/// over those, where it doesn't scroll. It says when the pointer moves over any of it.
private final class SideBySideView: NSView {
    private let gutter: LineNumberGutter
    private let scrollView: NSScrollView
    private let hunkButton: HunkButton
    /// Says that the pointer moved, or came or went.
    var pointerChanged: () -> Void = {}
    private(set) var isPointerInside = false

    init(gutter: LineNumberGutter, scrollView: NSScrollView, hunkButton: HunkButton) {
        self.gutter = gutter
        self.scrollView = scrollView
        self.hunkButton = hunkButton
        super.init(frame: .zero)
        // A band cut off at the top would otherwise put its button over the header.
        clipsToBounds = true
        addSubview(gutter)
        addSubview(scrollView)
        addSubview(hunkButton)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        pointerChanged()
    }

    override func mouseMoved(with event: NSEvent) {
        isPointerInside = true
        pointerChanged()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        pointerChanged()
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
