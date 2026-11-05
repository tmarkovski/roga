import AppKit

/// The button that takes a hunk out of the file. It shows on the hunk's band while
/// the pointer is anywhere in that hunk (decision 39). A band is one row of text tall,
/// which leaves it 1 point above and below.
final class HunkButton: NSButton {
    /// The index among the patch's lines of the header of the hunk it's on.
    var header: Int?

    private static let height: CGFloat = 15
    private static let padding: CGFloat = 6

    /// How big it draws.
    var size: NSSize {
        NSSize(width: (attributedTitle.size().width + Self.padding * 2).rounded(.up), height: Self.height)
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        isHidden = true
        wantsLayer = true
        setButtonType(.momentaryChange)
        attributedTitle = NSAttributedString(string: "Discard", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.systemRed,
        ])
        toolTip = "Discard Hunk"
        setAccessibilityLabel("Discard Hunk")
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Buttons aren't loaded from files")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// A layer's colors don't follow the appearance by themselves.
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 4
            layer?.borderWidth = 1
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
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
