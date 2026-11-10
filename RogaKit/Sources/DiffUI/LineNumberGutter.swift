import AppKit
import GitCore

/// The strip on the left of a diff, which stays put as the text scrolls
/// sideways: each line's numbers in the old and new file, and a bar beside each
/// changed line. An added line's bar is solid and a removed line's is striped,
/// so that they differ without relying on color. The numbers aren't in the
/// text, so that a selection copies only the code.
///
/// It's a view beside the scroll view rather than the scroll view's ruler,
/// because AppKit lays out text under a ruler, on the macOS this was built on.
///
/// It draws every row each time the text moves, which as strings took 12 ms for
/// a window of them. So each digit's glyph is found once for a font, in
/// `DiffMetrics`, and it draws them all at once.
final class LineNumberGutter: NSView {
    /// So that going from one file to another doesn't usually move the text.
    private static let fewestDigits = 3
    private static let edge: CGFloat = 10
    private static let gap: CGFloat = 8
    private static let barWidth: CGFloat = 4
    /// How far apart a striped bar's stripes are, measured along the bar.
    private static let stripeSpacing: CGFloat = 4
    private static let stripeWidth: CGFloat = 1.5

    private let textView: NSTextView

    var document: DiffDocument? {
        didSet {
            digits = max(document?.numberDigits ?? 0, Self.fewestDigits)
            metrics = document?.metrics ?? .current
            needsDisplay = true
        }
    }

    private var digits = LineNumberGutter.fewestDigits
    /// The measures of the font the document is in, which the numbers' size
    /// and the rows' baseline come from.
    private var metrics = DiffMetrics.current
    private var numberWidth: CGFloat { CGFloat(digits) * metrics.digitWidth }

    /// How wide the gutter needs to be for the current document.
    var thickness: CGFloat {
        (Self.edge + numberWidth * 2 + Self.gap * 2).rounded(.up)
    }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        // Rows cut off at the top would otherwise draw over the panel's header.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Gutters aren't loaded from files")
    }

    override var isFlipped: Bool { true }

    /// Draws stripes across some bars. Each stripe keeps its place in the text,
    /// so that they move with it rather than crawling along the bars.
    private func drawStripes(in bars: [CGRect], top: CGFloat, context: CGContext) {
        guard let first = bars.first, let last = bars.last else { return }
        let reach = Self.barWidth + 1
        var y = first.minY - (first.minY - top).truncatingRemainder(dividingBy: Self.stripeSpacing) - Self.stripeSpacing
        var ends: [CGPoint] = []
        while y < last.maxY + reach {
            ends.append(CGPoint(x: -1, y: y))
            ends.append(CGPoint(x: Self.barWidth + 1, y: y - reach - 1))
            y += Self.stripeSpacing
        }
        context.saveGState()
        context.clip(to: bars)
        DiffStyle.removedBar.setStroke()
        context.setLineWidth(Self.stripeWidth)
        context.strokeLineSegments(between: ends)
        context.restoreGState()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let document, let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        // Where the text view's rows are in this view, as the text scrolls.
        let top = convert(NSPoint.zero, from: textView).y + textView.textContainerOrigin.y
        let oldRight = Self.edge + numberWidth
        let newRight = oldRight + Self.gap + numberWidth
        var glyphs: [CGGlyph] = []
        var positions: [CGPoint] = []
        var solidBars: [CGRect] = []
        var stripedBars: [CGRect] = []
        // The bars beside a conflict's sides, by their color (decision 60).
        var coloredBars: [NSColor: [CGRect]] = [:]

        // This view is flipped, and glyphs would come out upside down. Their
        // positions go through this too, so they're negative below.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let metrics = metrics
        func add(_ number: Int?, right: CGFloat, baseline: CGFloat) {
            guard var number else { return }
            var x = right
            repeat {
                x -= metrics.digitWidth
                glyphs.append(metrics.digitGlyphs[number % 10])
                positions.append(CGPoint(x: x, y: baseline))
                number /= 10
            } while number > 0
        }

        let rect = NSRect(x: 0, y: bounds.minY - top, width: 1, height: bounds.height)
        let shown = layoutManager.glyphRange(forBoundingRect: rect, in: container)
        layoutManager.enumerateLineFragments(forGlyphRange: shown) { fragment, _, _, glyphs, _ in
            let index = document.lineIndex(atCharacter: layoutManager.characterIndexForGlyph(at: glyphs.location))
            let line = document.lines[index]
            let row = NSRect(x: 0, y: fragment.minY + top, width: self.bounds.width, height: fragment.height)
            if let color = document.background(ofRow: index) {
                color.setFill()
                row.fill(using: .sourceOver)
            }
            let baseline = -(row.minY + metrics.baseline)
            add(line.oldNumber, right: oldRight, baseline: baseline)
            add(line.newNumber, right: newRight, baseline: baseline)
            let bar = CGRect(x: 0, y: row.minY, width: Self.barWidth, height: row.height)
            if let conflicts = document.conflicts {
                if let color = conflicts.rows[index]?.bar { coloredBars[color, default: []].append(bar) }
                return
            }
            switch line.kind {
            case .added: solidBars.append(bar)
            case .removed: stripedBars.append(bar)
            default: break
            }
        }

        NSColor.tertiaryLabelColor.setFill()
        CTFontDrawGlyphs(metrics.numberFont, glyphs, positions, glyphs.count, context)
        for (color, bars) in coloredBars {
            color.setFill()
            context.fill(bars)
        }
        DiffStyle.addedBar.setFill()
        context.fill(solidBars)
        drawStripes(in: stripedBars, top: top, context: context)
    }
}
