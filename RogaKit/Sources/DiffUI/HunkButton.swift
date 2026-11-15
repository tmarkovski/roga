import AppKit
import ThemeUI

/// A button that does something to a hunk: takes it out of the file, or stages or
/// unstages it. The buttons show on the hunk's band while the pointer is anywhere in
/// that hunk (decision 39), at the size of the small buttons elsewhere.
///
/// It's only its words, with no border, and fills with gray while the pointer is on
/// it, as the words beside a file's path in the diff panel's header do. At rest it's
/// filled with the panel's own color, which looks like nothing, so that a long
/// header doesn't show through it.
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
    /// How tall it is, which a band in the smallest code fonts makes less than
    /// usual (decision 73).
    var height: CGFloat = 22
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

    private static let padding: CGFloat = 8
    /// The red of what was removed, which follows the theme as it's drawn.
    static let red = ColorTheme.following(\.removed)

    var size: NSSize {
        NSSize(width: (attributedTitle.size().width + Self.padding * 2).rounded(.up), height: height)
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

    /// Discarding is in the color theme's red, as every other button that takes
    /// something away is (decision 71).
    private func updateTitle() {
        attributedTitle = NSAttributedString(string: command.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: command == .discard ? Self.red : NSColor.labelColor,
        ])
        toolTip = command.title
        setAccessibilityLabel(command.title)
    }

    /// A layer's colors don't follow the appearance by themselves.
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 6
            layer?.backgroundColor = Self.fill(isHovering: isHovering, isPressing: isPressing).cgColor
        }
    }

    /// What a button on a band is filled with, in the appearance being drawn in,
    /// which a conflict's band's buttons share. It's the panel's own color at rest,
    /// and the gray while the pointer is on it is the text's color over the panel's,
    /// as much of it as the other buttons' fills have.
    static func fill(isHovering: Bool, isPressing: Bool) -> NSColor {
        let surface = ConflictColors.button
        let amount: CGFloat = isPressing ? 0.11 : isHovering ? 0.075 : 0
        return amount > 0 ? surface.blended(withFraction: amount, of: .labelColor) ?? surface : surface
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
