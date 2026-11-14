import AppKit

/// A button that does something to a hunk: takes it out of the file, or stages or
/// unstages it. The buttons show on the hunk's band while the pointer is anywhere in
/// that hunk (decision 39). A band is one row of text tall, which leaves it 1 point
/// above and below, or more in a larger code font.
///
/// It keeps its background and its thin border, because it can sit over the end of
/// the hunk's header. While the pointer is on it, it fills with gray, as the buttons
/// on a conflict's band do.
final class HunkButton: NSButton {
    enum Command: String {
        case discard, stage, unstage

        var title: String {
            switch self {
            case .discard: "Discard Hunk"
            case .stage: "Stage Hunk"
            case .unstage: "Unstage Hunk"
            }
        }
    }

    /// What it does, which is in its words.
    var command: Command {
        didSet {
            if command != oldValue { updateTitle() }
        }
    }
    /// The index among the patch's lines of the header of the hunk it's on.
    var header: Int?
    /// How tall a row of the diff is, in the code font it's in (decision 73).
    var rowHeight: CGFloat = 17
    /// Whether the pointer is on it, which the view that places it says, since
    /// it moves under a pointer that stays put as the text scrolls.
    var isHovering = false {
        didSet {
            if isHovering != oldValue { updateColors() }
        }
    }
    private var isPressing = false {
        didSet { updateColors() }
    }

    /// How tall it is where a row has the room.
    private static let height: CGFloat = 15
    private static let padding: CGFloat = 6

    /// How big it draws: no taller than leaves a point of its band above and
    /// below it, which the smallest code font makes a point less.
    var size: NSSize {
        NSSize(width: (attributedTitle.size().width + Self.padding * 2).rounded(.up), height: min(Self.height, rowHeight - 2))
    }

    init(_ command: Command) {
        self.command = command
        super.init(frame: .zero)
        isBordered = false
        isHidden = true
        wantsLayer = true
        setButtonType(.momentaryChange)
        updateTitle()
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Buttons aren't loaded from files")
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

    /// Discarding is in red, as it is everywhere else.
    private func updateTitle() {
        attributedTitle = NSAttributedString(string: command.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: command == .discard ? NSColor.systemRed : NSColor.labelColor,
        ])
        toolTip = command.title
        setAccessibilityLabel(command.title)
    }

    /// A layer's colors don't follow the appearance by themselves.
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 4
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.cgColor
            let fill = isPressing ? ConflictColors.buttonPressed : isHovering ? ConflictColors.buttonHover : NSColor.textBackgroundColor
            layer?.backgroundColor = fill.cgColor
        }
    }

    /// The text under it shows a text cursor, and this isn't text.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

extension NSEvent {
    /// Whether this is the second click or later of a double-click. A button that
    /// takes something away ignores these, because what's next moves up under the
    /// pointer. Only mouse events can be asked for their click count, and asking
    /// another kind raises an exception, which a menu's key equivalent would be.
    public var isRepeatedClick: Bool {
        (type == .leftMouseDown || type == .leftMouseUp) && clickCount > 1
    }
}
