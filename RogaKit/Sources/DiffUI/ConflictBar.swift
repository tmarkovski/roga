import AppKit
import GitCore

/// What someone asked to do about one of a file's conflicts (decision 60).
public enum ConflictRequest: Sendable, Hashable {
    /// Resolve the conflict, by its index, this way.
    case choose(Int, ConflictedFile.Choice)
    /// Put back a conflict that was resolved here.
    case undo(Int)
    /// Show a resolved conflict's sides under what it kept, or stop showing them.
    case showSides(Int, Bool)
}

/// A conflict's band: what it says on the left and its buttons on the right, one
/// for keeping each side, Keep Both and Edit…, or Show Sides and Undo once it's
/// resolved. The buttons show on every band in view rather than waiting for the
/// pointer, as a hunk's Discard does, because resolving is the task while a file
/// has conflicts. It's over the text rather than in it, so it stays put as the text
/// scrolls sideways, and so that its label can be centered in a band that's taller
/// than a row of text.
final class ConflictBar: NSView {
    enum Action {
        case keep(ConflictedFile.Choice)
        case edit
        case undo
        case showSides(Bool)
    }

    /// How tall a bar is over rows of some height: as tall as its band.
    static func height(lineHeight: CGFloat) -> CGFloat {
        lineHeight * CGFloat(ConflictBand.rowCount)
    }

    /// The conflict it's for.
    private(set) var conflict = 0
    private(set) var isResolved = false
    private(set) var showsSides = false
    /// Says which button was pressed, and the button.
    var onAction: ((ConflictBar, Action, NSButton) -> Void)?
    /// What scrolls when someone scrolls over the bar, which isn't inside it.
    weak var scrollTarget: NSScrollView?

    private var buttons: [BarButton] = []
    private var sides: ConflictSides?
    private var canResolve = false
    private let label = NSTextField(labelWithString: "")
    /// Where the label starts, which is where the text under the band starts.
    private var textStart: CGFloat = 0

    private static let spacing: CGFloat = 4
    private static let trailing: CGFloat = 8
    private static let iconSize: CGFloat = 12
    private static let iconGap: CGFloat = 7
    private static let labelHeight: CGFloat = 16

    init() {
        super.init(frame: .zero)
        isHidden = true
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        addSubview(label)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Bars aren't loaded from files")
    }

    override var isFlipped: Bool { true }

    /// Sets which conflict it's for, and makes its buttons if they've changed.
    func show(_ band: ConflictBand, sides: ConflictSides, of count: Int, canResolve: Bool) {
        let changed = sides != self.sides || band.isResolved != isResolved || band.showsSides != showsSides
            || canResolve != self.canResolve || (buttons.isEmpty && canResolve)
        if band.isResolved != isResolved { needsDisplay = true }
        conflict = band.conflict
        isResolved = band.isResolved
        showsSides = band.showsSides
        self.canResolve = canResolve
        self.sides = sides
        if changed { makeButtons(sides) }
        let which = "Conflict \(band.conflict + 1) of \(count)"
        label.attributedStringValue = Self.title(which: which, kept: band.isResolved ? band.kept : nil)
        for button in buttons { button.setAccessibilityLabel("\(button.title), conflict \(band.conflict + 1) of \(count)") }
    }

    /// The label says which conflict it is, or, once it's resolved, how, and which.
    private static func title(which: String, kept: String?) -> NSAttributedString {
        let size: CGFloat = 12.5
        guard let kept else {
            return NSAttributedString(string: which, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: ConflictColors.unresolved,
            ])
        }
        return NSAttributedString(string: "\(kept)  \(which)", attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: ConflictColors.secondaryText,
        ])
    }

    private func makeButtons(_ sides: ConflictSides) {
        buttons.forEach { $0.removeFromSuperview() }
        let made: [(String, BarButton.Look, Action)]
        if !canResolve {
            made = []
        } else if isResolved {
            made = [(showsSides ? "Hide Sides" : "Show Sides", .plain, .showSides(!showsSides)), ("Undo", .link, .undo)]
        } else {
            made = [
                (sides.ours.keepTitle, .side(ConflictColors.ours), .keep(.ours)),
                (sides.theirs.keepTitle, .side(ConflictColors.theirs), .keep(.theirs)),
                ("Keep Both", .plain, .keep(.both)),
                ("Edit…", .plain, .edit),
            ]
        }
        buttons = made.map { title, look, action in
            let button = BarButton(title: title, look: look)
            button.target = self
            button.action = #selector(pressed)
            button.barAction = action
            addSubview(button)
            return button
        }
        arrange()
    }

    /// Takes up a band, from the frame it's given, with its label starting at `textStart`.
    func place(in frame: NSRect, textStart: CGFloat) {
        self.frame = frame
        if textStart != self.textStart {
            self.textStart = textStart
            needsDisplay = true
        }
        arrange()
    }

    private func arrange() {
        var x = bounds.width - Self.trailing
        for button in buttons.reversed() {
            let size = button.size
            x -= size.width
            button.frame = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
            x -= Self.spacing
        }
        label.frame = NSRect(
            x: textStart, y: ((bounds.height - Self.labelHeight) / 2).rounded(),
            width: max(x - 8 - textStart, 0), height: Self.labelHeight
        )
    }

    @objc private func pressed(_ button: BarButton) {
        // The next conflict moves up under the pointer once this one is resolved,
        // and that's not what a double-click meant to resolve.
        guard NSApp?.currentEvent?.isRepeatedClick != true, let action = button.barAction else { return }
        onAction?(self, action, button)
    }

    override func scrollWheel(with event: NSEvent) {
        scrollTarget?.scrollWheel(with: event)
    }

    // The text under a band has a text cursor, and cursor rectangles that overlap
    // can go either way, so the bar also says so each time the pointer moves.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        ConflictColors.line.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Drawn on a 24-point grid, as the canvas's icons are.
        context.saveGState()
        context.translateBy(x: textStart - Self.iconGap - Self.iconSize, y: ((bounds.height - Self.iconSize) / 2).rounded())
        context.scaleBy(x: Self.iconSize / 24, y: Self.iconSize / 24)
        context.addPath(isResolved ? Self.check : Self.warning)
        context.setStrokeColor((isResolved ? ConflictColors.kept : ConflictColors.unresolved).cgColor)
        context.setLineWidth(2.2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }

    private static let check: CGPath = {
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: 20, y: 6), CGPoint(x: 9, y: 17), CGPoint(x: 4, y: 12)])
        return path
    }()

    private static let warning: CGPath = {
        let top = CGPoint(x: 12, y: 0.97)
        let right = CGPoint(x: 23.44, y: 21)
        let left = CGPoint(x: 0.56, y: 21)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 12, y: 21))
        path.addArc(tangent1End: right, tangent2End: top, radius: 2)
        path.addArc(tangent1End: top, tangent2End: left, radius: 2)
        path.addArc(tangent1End: left, tangent2End: CGPoint(x: 12, y: 21), radius: 2)
        path.closeSubpath()
        path.move(to: CGPoint(x: 12, y: 9))
        path.addLine(to: CGPoint(x: 12, y: 13))
        path.move(to: CGPoint(x: 12, y: 17))
        path.addLine(to: CGPoint(x: 12.01, y: 17))
        return path
    }()
}

/// A button on a conflict's band, drawn to the canvas's measurements.
private final class BarButton: NSButton {
    enum Look {
        case plain
        /// In the color of the side it keeps.
        case side(NSColor)
        /// Words in the action color, with no border until the pointer is over it.
        case link
    }

    static let height: CGFloat = 22
    var barAction: ConflictBar.Action?
    private let look: Look
    private var isHovering = false {
        didSet { updateColors() }
    }
    private var isPressing = false {
        didSet { updateColors() }
    }

    private var padding: CGFloat {
        if case .link = look { 4 } else { 9 }
    }

    var size: NSSize {
        NSSize(width: (attributedTitle.size().width + padding * 2).rounded(.up), height: Self.height)
    }

    init(title: String, look: Look) {
        self.look = look
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryChange)
        let color: NSColor = switch look {
        case .plain: ConflictColors.text
        case .side(let color): color
        case .link: ConflictColors.action
        }
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ])
        toolTip = title
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Buttons aren't loaded from files")
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressing = true
        // This returns when the button is let go.
        super.mouseDown(with: event)
        isPressing = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// A layer's colors don't follow the appearance by themselves.
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 6
            let rest: NSColor
            switch look {
            case .plain:
                rest = ConflictColors.button
                layer?.borderWidth = 1
                layer?.borderColor = ConflictColors.line.cgColor
            case .side(let color):
                rest = ConflictColors.button
                layer?.borderWidth = 1
                layer?.borderColor = color.cgColor
            case .link:
                rest = .clear
                layer?.borderWidth = 0
            }
            let fill = isPressing ? ConflictColors.buttonPressed : isHovering ? ConflictColors.buttonHover : rest
            layer?.backgroundColor = fill.cgColor
        }
    }
}

/// Where someone writes the lines that resolve a conflict, starting from both sides.
/// It shows under the band's Edit… button.
final class ConflictEditor: NSViewController {
    private let scroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { scroll.documentView as! NSTextView }
    private let initialText: String
    private let heading: String
    /// Says what was written, or nil for Cancel.
    var onFinish: ((String?) -> Void)?

    init(heading: String, text: String) {
        self.heading = heading
        initialText = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Editors aren't loaded from files")
    }

    override func loadView() {
        let lines = initialText.split(separator: "\n", omittingEmptySubsequences: false).count
        // The code font in use, which is the one the conflict's lines show in.
        let metrics = DiffMetrics.current
        let textHeight = min(max(CGFloat(lines + 1), 4), 16) * metrics.lineHeight + 10
        let width: CGFloat = 560
        let inset: CGFloat = 14

        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: "Edit the combined content from both sides to resolve this conflict. Changes apply only to this conflict.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor

        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = metrics.font
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.string = initialText
        textView.setAccessibilityLabel(heading)
        scroll.borderType = .bezelBorder

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        let keep = NSButton(title: "Apply Resolution", target: self, action: #selector(keepPressed))
        // Return makes a new line, so Command-Return keeps them.
        keep.keyEquivalent = "\r"
        keep.keyEquivalentModifierMask = .command
        keep.toolTip = "Apply Resolution (⌘↩)"
        let buttons = NSStackView(views: [NSView(), cancel, keep])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, note, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [note, scroll, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scroll.heightAnchor.constraint(equalToConstant: textHeight).isActive = true
        stack.widthAnchor.constraint(equalToConstant: width - inset * 2).isActive = true

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ])
        let size = container.fittingSize
        container.setFrameSize(size)
        preferredContentSize = size
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
    }

    @objc private func cancelPressed() {
        onFinish?(nil)
    }

    @objc private func keepPressed() {
        onFinish?(textView.string)
    }
}
