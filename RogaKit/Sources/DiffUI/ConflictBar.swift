import AppKit
import GitCore

/// What someone asked to do about one of a file's conflicts (decision 60).
public enum ConflictRequest: Sendable, Hashable {
    /// Resolve the conflict, by its index, this way.
    case choose(Int, ConflictedFile.Choice)
    /// Put back a conflict that was resolved here.
    case undo(Int)
}

/// The buttons on a conflict's band, at the edge of the view: one for keeping each
/// side, Keep Both and Edit…, or Undo once it's resolved. They show on every band in
/// view rather than waiting for the pointer, as a hunk's Discard does, because
/// resolving is the task while a file has conflicts.
final class ConflictBar: NSView {
    enum Action {
        case keep(ConflictedFile.Choice)
        case edit
        case undo
    }

    /// The conflict it's for.
    private(set) var conflict = 0
    private(set) var isResolved = false
    /// Says which button was pressed, and the button.
    var onAction: ((ConflictBar, Action, NSButton) -> Void)?

    private var buttons: [BarButton] = []
    private var sides: ConflictSides?
    private static let spacing: CGFloat = 4

    init() {
        super.init(frame: .zero)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Bars aren't loaded from files")
    }

    /// How big it draws.
    var size: NSSize {
        let width = buttons.reduce(0) { $0 + $1.size.width } + Self.spacing * CGFloat(max(buttons.count - 1, 0))
        return NSSize(width: width, height: BarButton.height)
    }

    /// Sets which conflict it's for, and makes its buttons if they've changed.
    func show(_ band: ConflictBand, sides: ConflictSides, of count: Int) {
        let changed = sides != self.sides || band.isResolved != isResolved || buttons.isEmpty
        conflict = band.conflict
        isResolved = band.isResolved
        self.sides = sides
        if changed { makeButtons(sides) }
        let which = "conflict \(band.conflict + 1) of \(count)"
        for button in buttons { button.setAccessibilityLabel("\(button.title), \(which)") }
    }

    private func makeButtons(_ sides: ConflictSides) {
        buttons.forEach { $0.removeFromSuperview() }
        let made: [(String, NSColor, Action)] = isResolved
            ? [("Undo", .controlAccentColor, .undo)]
            : [
                (sides.ours.keepTitle, .systemBlue, .keep(.ours)),
                (sides.theirs.keepTitle, .systemPurple, .keep(.theirs)),
                ("Keep Both", .labelColor, .keep(.both)),
                ("Edit…", .labelColor, .edit),
            ]
        buttons = made.map { title, color, action in
            let button = BarButton(title: title, color: color)
            button.target = self
            button.action = #selector(pressed)
            button.barAction = action
            addSubview(button)
            return button
        }
        var x: CGFloat = 0
        for button in buttons {
            let size = button.size
            button.frame = NSRect(x: x, y: 0, width: size.width, height: size.height)
            x += size.width + Self.spacing
        }
    }

    @objc private func pressed(_ button: BarButton) {
        // The next conflict moves up under the pointer once this one is resolved,
        // and that's not what a double-click meant to resolve.
        guard NSApp?.currentEvent?.isRepeatedClick != true, let action = button.barAction else { return }
        onAction?(self, action, button)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// A small button with a border, like a hunk's Discard.
private final class BarButton: NSButton {
    static let height: CGFloat = 15
    private static let padding: CGFloat = 6
    var barAction: ConflictBar.Action?

    var size: NSSize {
        NSSize(width: (attributedTitle.size().width + Self.padding * 2).rounded(.up), height: Self.height)
    }

    init(title: String, color: NSColor) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryChange)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color,
        ])
        toolTip = title
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

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 4
            layer?.borderWidth = 1
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
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
        let textHeight = min(max(CGFloat(lines + 1), 4), 16) * DiffStyle.lineHeight + 10
        let width: CGFloat = 560
        let inset: CGFloat = 14

        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: "This starts with both sides. Only these lines change, and the rest of the file stays as it is.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor

        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = DiffStyle.font
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
        let keep = NSButton(title: "Keep These Lines", target: self, action: #selector(keepPressed))
        // Return makes a new line, so Command-Return keeps them.
        keep.keyEquivalent = "\r"
        keep.keyEquivalentModifierMask = .command
        keep.toolTip = "Keep These Lines (⌘↩)"
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
