import AppKit
import QuartzCore

/// A light in the brand's orange that runs left to right through words a row
/// has drawn under it, for the row for uncommitted changes while an agent makes
/// them (decision 100), as decision 68's light runs along an agent's command.
///
/// It's a band of orange that fades out at both ends, cut to the shape of the
/// words by a mask drawn from the same text, in the same place, as the row
/// draws it, so that only the letters light up. Core Animation moves the band,
/// so neither the list nor the main thread does anything for each frame. It
/// stops whenever the window can't be seen, being minimized, hidden, on
/// another Space or fully covered, and for someone who asked for less motion,
/// and then nothing of it shows.
final class TextShimmerView: NSView {
    /// What the light runs through.
    struct Words: Equatable {
        var text: String
        var font: NSFont
        /// Where the row draws the text, in this view's coordinates.
        var frame: NSRect
    }

    var words: Words? {
        didSet {
            guard words != oldValue else { return }
            needsLayout = true
        }
    }

    private let band = CAGradientLayer()
    /// Holds the band, cut to the words by `glyphs`, since the view's own
    /// layer is AppKit's.
    private let lit = CALayer()
    private let glyphs = CALayer()
    /// What the mask was last drawn for, so that it's drawn again only when
    /// that changes.
    private var maskedFor: (words: Words, size: NSSize, scale: CGFloat)?

    /// How long the light takes to cross the words.
    static let pass: CFTimeInterval = 2.4
    static let animationKey = "shimmer"
    /// How wide the band is next to the words, which is the canvas's: lit
    /// across about a quarter of the room it travels, and at most this wide.
    private static let bandShare: CGFloat = 0.72
    private static let widestBand: CGFloat = 96

    /// The brand's orange, as `Palette.action` has it.
    static let color = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 240 / 255, green: 129 / 255, blue: 63 / 255, alpha: 1)
            : NSColor(srgbRed: 201 / 255, green: 68 / 255, blue: 2 / 255, alpha: 1)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.isHidden = true
        lit.addSublayer(band)
        lit.mask = glyphs
        layer?.addSublayer(lit)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// Clicks and hovering go to the row.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    /// Whether the light is running through the words right now, which tests
    /// read.
    var isShimmering: Bool {
        band.animation(forKey: Self.animationKey) != nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lit.frame = bounds
        glyphs.frame = bounds
        drawMask()
        CATransaction.commit()
        updateShimmering()
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let orange = Self.color.cgColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            band.colors = [orange.copy(alpha: 0) ?? orange, orange, orange.copy(alpha: 0) ?? orange]
            CATransaction.commit()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(visibilityChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
        }
        updateShimmering()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.removeObserver(self, name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        if superview != nil {
            workspace.addObserver(
                self, selector: #selector(visibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
            )
        }
    }

    @objc private func visibilityChanged(_ notification: Notification) {
        updateShimmering()
    }

    /// Whether the light should run: there are words, someone can see them,
    /// and nobody asked for less motion.
    private var shouldShimmer: Bool {
        guard let words, words.frame.width > 0, let window, window.occlusionState.contains(.visible) else { return false }
        return !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Starts the light, or stops it and hides the band, so that the render
    /// server has nothing to play for words nobody sees.
    func updateShimmering() {
        guard shouldShimmer, let words else {
            band.removeAnimation(forKey: Self.animationKey)
            band.isHidden = true
            return
        }
        let width = Self.textWidth(of: words)
        let bandWidth = min(Self.widestBand, max(24, width * Self.bandShare))
        let start = words.frame.minX - bandWidth / 2
        let end = words.frame.minX + width + bandWidth / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.isHidden = false
        band.bounds = CGRect(x: 0, y: 0, width: bandWidth, height: bounds.height)
        band.position = CGPoint(x: start, y: bounds.midY)
        CATransaction.commit()
        let shimmer = Self.shimmer(from: start, to: end)
        if let running = band.animation(forKey: Self.animationKey) as? CABasicAnimation,
           running.fromValue as? CGFloat == start, running.toValue as? CGFloat == end {
            return
        }
        band.add(shimmer, forKey: Self.animationKey)
    }

    /// The band's travel from where the words start to past where they end,
    /// over and over.
    static func shimmer(from start: CGFloat, to end: CGFloat) -> CABasicAnimation {
        let shimmer = CABasicAnimation(keyPath: "position.x")
        shimmer.fromValue = start
        shimmer.toValue = end
        shimmer.duration = pass
        shimmer.repeatCount = .infinity
        shimmer.isRemovedOnCompletion = false
        return shimmer
    }

    /// How much of its frame the text takes, since the light shouldn't run
    /// on past short words.
    private static func textWidth(of words: Words) -> CGFloat {
        min(words.frame.width, ceil((words.text as NSString).size(withAttributes: [.font: words.font]).width))
    }

    /// Draws the words, in the same place and cut short the same way as the
    /// row draws them, as the mask's opaque part.
    private func drawMask() {
        let scale = window?.backingScaleFactor ?? 2
        guard let words, bounds.width >= 1, bounds.height >= 1 else {
            glyphs.contents = nil
            maskedFor = nil
            return
        }
        if let maskedFor, maskedFor.words == words, maskedFor.size == bounds.size, maskedFor.scale == scale { return }
        maskedFor = (words, bounds.size, scale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((bounds.width * scale).rounded(.up)),
            pixelsHigh: Int((bounds.height * scale).rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        bitmap.size = bounds.size
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            // Top-down, as the row draws.
            context.cgContext.translateBy(x: 0, y: bounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
            (words.text as NSString).draw(
                with: words.frame,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: words.font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        glyphs.contents = bitmap.cgImage
        glyphs.contentsScale = scale
    }
}
