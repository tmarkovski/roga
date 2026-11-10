import AppKit
import GitCore
import ThemeUI

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
    /// Whether the view only shows a diff, as the sample in Settings does: its
    /// text can't be selected, and it has no scrollers.
    public var isPicture = false {
        didSet {
            configureTextView()
            scrollView.hasVerticalScroller = !isPicture
            scrollView.hasHorizontalScroller = !isPicture
        }
    }

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
    /// working on them, or nil while none is (decision 68). The view that's made
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
    /// How many lines show above a whole file's first change when the file is
    /// selected, which is as many as git puts above a hunk's.
    static let linesAboveFirstChange = 3
    /// Where the text should be scrolled to once the view has a size.
    private var waitingPosition: NSPoint?

    /// How tall the view has to be to show a patch of some lines in a code font
    /// without scrolling: a row for each, and the space above and below the text.
    public static func height(lines: Int, in font: CodeFont = .current) -> CGFloat {
        CGFloat(lines) * DiffMetrics.of(font).lineHeight + inset * 2
    }

    /// The measures of the font the document showing was built in, which say
    /// where its rows are. With no document, they're the font's in use.
    private var metrics: DiffMetrics {
        document?.metrics ?? .current
    }
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

        gutter = LineNumberGutter(textView: textView)
        sides = SideBySideView(gutter: gutter, scrollView: scrollView, hunkButton: hunkButton)
        view = sides

        super.init()

        hunkButton.target = self
        hunkButton.action = #selector(hunkButtonPressed)
        sides.pointerChanged = { [weak self] in self?.updateHunkButton() }
        textView.menuItem = { [weak self] point in self?.hunkMenuItem(atTextY: point.y) }
        textView.isCovered = { [weak self] point in self?.isCovered(atWindowPoint: point) ?? false }

        configureTextView()
        followMetrics()
        let clipView = scrollView.contentView
        clipView.postsFrameChangedNotifications = true
        clipView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clipViewChangedSize), name: NSView.frameDidChangeNotification, object: clipView)
        center.addObserver(self, selector: #selector(clipViewScrolled), name: NSView.boundsDidChangeNotification, object: clipView)
    }

    @objc private func clipViewChangedSize() {
        updateTextSize()
        if let position = waitingPosition, scrollView.contentSize.height > 0 {
            waitingPosition = nil
            textView.scroll(position)
        }
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

    /// Shows a patch from its start, which for a whole file is a few lines
    /// above its first change.
    ///
    /// - Parameter keepingPosition: Whether the text stays scrolled to the same
    ///   place, for a newer copy of the document showing. A copy in the other
    ///   layout stays at the same line of the file.
    public func show(_ document: DiffDocument, keepingPosition: Bool = false) {
        guard document !== self.document else { return }
        var position = scrollView.contentView.bounds.origin
        let old = metrics
        if !keepingPosition {
            position = Self.start(of: document)
        } else if let shown = self.document, shown.layout != document.layout, !shown.hasConflicts, !document.hasConflicts {
            // A copy in the other layout has other rows, so the same place is
            // the same line of the file.
            position.x *= document.metrics.columnWidth / old.columnWidth
            position.y = Self.position(in: document, ofTheLineAt: position.y, in: shown)
        } else if old !== document.metrics {
            // A copy in another font has rows of another height, so the same place
            // is the same row and column rather than the same distance.
            position.x *= document.metrics.columnWidth / old.columnWidth
            position.y = (position.y * document.metrics.lineHeight / old.lineHeight).rounded()
        }
        // The selection is a place in the old text, which the new one may not have.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        letGoOfDocument()
        self.document = document
        gutter.document = document
        followMetrics()
        view.needsLayout = true
        // An earlier view may still have this document, when a window goes to
        // another worktree and back.
        document.container.textView?.textContainer = nil
        document.container.textView = textView
        configureTextView()
        textView.sizeToFit()
        updateTextSize()
        textView.needsDisplay = true
        textView.scroll(position)
        // A view that hasn't been given its size yet can't scroll, so the text
        // goes there once it has one.
        waitingPosition = scrollView.contentSize.height > 0 ? nil : position
        updateHunkButton()
        editor?.close()
        updateConflictBars()
    }

    /// Where a document that's just been selected starts. Hunks start at the
    /// top. A whole file starts a few lines above its first change, because
    /// the top of a long file can be a long way from one (decision 74).
    static func start(of document: DiffDocument) -> NSPoint {
        guard document.layout == .inline, let row = document.firstChangedRow, row > linesAboveFirstChange else { return .zero }
        return NSPoint(x: 0, y: inset + CGFloat(row - linesAboveFirstChange) * document.metrics.lineHeight)
    }

    /// How far down a document in the other layout has to be scrolled to stay
    /// at the same line of the file (decision 74). It goes by the first line of
    /// the file in view, which stays as far from the top of the view as it was.
    /// When that line isn't in the hunks, the hunk that comes next starts at
    /// the top instead, and so does a hunk whose first line it is.
    static func position(in document: DiffDocument, ofTheLineAt y: CGFloat, in shown: DiffDocument) -> CGFloat {
        // How many rows are above the view, which is a part of one when a row
        // is cut off at the top.
        let rowsAbove = (y - inset) / shown.metrics.lineHeight
        guard let anchor = shown.fileRow(atOrAfter: Int(rowsAbove.rounded(.down))) else { return 0 }
        var (row, isExact) = document.row(showing: shown.lines[anchor])
        var rowsBelowTop = isExact ? CGFloat(anchor) - rowsAbove : 0
        // A hunk's first line at the top of the view brings the hunk's header
        // with it, which would otherwise be just out of view.
        if isExact, rowsBelowTop <= 0, row > 0, document.lines[row - 1].kind == .hunkHeader {
            row -= 1
            rowsBelowTop = 0
        }
        let position = inset + (CGFloat(row) - rowsBelowTop) * document.metrics.lineHeight
        // The first row has the space above the text over it, which shows
        // when the text is at its start.
        return position <= inset ? 0 : position.rounded()
    }

    /// Sets what depends on the font: how far a step of scrolling goes, and how
    /// tall a hunk's button can be on its band.
    private func followMetrics() {
        scrollView.verticalLineScroll = metrics.lineHeight
        scrollView.horizontalLineScroll = metrics.columnWidth * 4
        hunkButton.rowHeight = metrics.lineHeight
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
        let row = ((y - textView.textContainerOrigin.y) / metrics.lineHeight).rounded(.down)
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
        let top = textView.textContainerOrigin.y + CGFloat(header) * metrics.lineHeight
        let band = view.convert(NSRect(x: 0, y: top, width: 1, height: metrics.lineHeight), from: textView)
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
        let item = NSMenuItem(title: "Discard hunk", action: #selector(hunkMenuItemChosen), keyEquivalent: "")
        item.target = self
        item.representedObject = header
        return item
    }

    @objc private func hunkMenuItemChosen(_ item: NSMenuItem) {
        guard let header = item.representedObject as? Int else { return }
        discardHunk?(header)
    }

    // MARK: Conflicts

    private func isCovered(atWindowPoint point: NSPoint) -> Bool {
        let inView = view.convert(point, from: nil)
        let controls: [NSView] = conflictBars + [hunkButton]
        return controls.contains { !$0.isHidden && $0.frame.contains(inView) }
    }

    /// Puts a bar on each conflict's band in view, as wide as the view, so that its
    /// label and buttons stay put as the text scrolls sideways. A bar has no buttons
    /// while the conflicts can't be resolved from here.
    func updateConflictBars() {
        updateConflictOutlines()
        guard let document, let conflicts = document.conflicts, !document.conflictBands.isEmpty else {
            conflictBars.forEach { $0.isHidden = true }
            return
        }
        let clip = scrollView.contentView
        let visible = view.convert(clip.bounds, from: clip)
        let origin = textView.textContainerOrigin.y
        let shown = textView.visibleRect
        let firstRow = Int(((shown.minY - origin) / metrics.lineHeight).rounded(.down))
        let lastRow = Int(((shown.maxY - origin) / metrics.lineHeight).rounded(.up))
        let bands = document.conflictBands.filter { $0.row + ConflictBand.rowCount > firstRow && $0.row <= lastRow }
        let count = document.conflictBands.count
        while conflictBars.count < bands.count {
            let bar = ConflictBar()
            bar.onAction = { [weak self] bar, action, button in self?.conflictAction(action, of: bar, from: button) }
            bar.scrollTarget = scrollView
            sides.addSubview(bar)
            conflictBars.append(bar)
        }
        for (index, bar) in conflictBars.enumerated() {
            guard index < bands.count else {
                bar.isHidden = true
                continue
            }
            let band = bands[index]
            bar.show(band, sides: conflicts.sides, of: count, canResolve: resolveConflict != nil)
            let top = origin + CGFloat(band.row) * metrics.lineHeight
            let row = view.convert(NSRect(x: 0, y: top, width: 1, height: ConflictBar.height(lineHeight: metrics.lineHeight)), from: textView)
            bar.place(in: NSRect(x: 0, y: row.minY, width: visible.maxX, height: row.height), textStart: gutter.thickness + DiffStyle.textPadding)
            bar.isHidden = row.maxY <= visible.minY || row.minY >= visible.maxY
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
        let firstRow = Int(((shown.minY - origin) / metrics.lineHeight).rounded(.down))
        let lastRow = Int(((shown.maxY - origin) / metrics.lineHeight).rounded(.up))
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
                NSRect(x: 0, y: origin + CGFloat(rows.lowerBound) * metrics.lineHeight, width: 1, height: CGFloat(rows.count) * metrics.lineHeight),
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
        textView.isSelectable = !isPicture
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
        textView.scrollToVisible(rect.insetBy(dx: -metrics.columnWidth * 8, dy: -metrics.lineHeight * 3))
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
        let width = CGFloat(document?.columns ?? 0) * metrics.columnWidth + DiffStyle.textPadding * 2
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
