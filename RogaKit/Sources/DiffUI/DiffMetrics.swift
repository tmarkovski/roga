import AppKit
import Synchronization
import ThemeUI

/// What a code font comes to in a diff (decision 73): the fonts themselves, how
/// tall a row is and how wide a column. Every line has the same height, whatever
/// fonts its characters fall back on, and lines don't wrap, so each line of a
/// patch is one row.
///
/// A document keeps the ones it was built with, and what shows it reads them
/// from the document. So a document shows as it was built while another font is
/// chosen, until it's built again in that one.
nonisolated final class DiffMetrics: @unchecked Sendable {
    // Fonts and paragraph styles can't change once they exist, and the builder
    // reads these away from the main actor.
    let codeFont: CodeFont
    let font: NSFont
    /// For a heading among the code, such as the name of a conflict's side.
    let boldFont: NSFont
    /// How tall every row is.
    let lineHeight: CGFloat
    /// How far below the top of a row its text stands.
    let baseline: CGFloat
    /// The width of one column of text.
    let columnWidth: CGFloat
    let paragraph: NSParagraphStyle

    /// The line numbers' font: the system's, with digits of one width, a point
    /// smaller than the code, whatever the code's font is.
    let numberFont: NSFont
    let digitWidth: CGFloat
    /// The glyphs of 0 to 9 in the numbers' font.
    let digitGlyphs: [CGGlyph]

    /// How many times the font's own line a row is tall, which leaves air
    /// between lines of code. The system's font at 12 points comes to 17.
    static let lineSpacing: CGFloat = 1.2

    init(_ codeFont: CodeFont) {
        self.codeFont = codeFont
        let font = codeFont.font()
        self.font = font
        boldFont = codeFont.font(isBold: true)
        // A whole number of points, so that every row starts on a pixel.
        let lineHeight = ((font.ascender - font.descender + font.leading) * Self.lineSpacing).rounded()
        self.lineHeight = lineHeight
        let columnWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        self.columnWidth = columnWidth

        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.defaultTabInterval = columnWidth * CGFloat(DiffStyle.tabWidth)
        paragraph.tabStops = []
        self.paragraph = paragraph
        baseline = Self.baseline(of: font, in: paragraph)

        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(codeFont.size) - 1, weight: .regular)
        self.numberFont = numberFont
        digitWidth = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
        let digits = Array("0123456789".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: digits.count)
        CTFontGetGlyphsForCharacters(numberFont, digits, &glyphs, digits.count)
        digitGlyphs = glyphs
    }

    /// Where TextKit stands a font's text in a row. It puts the extra height of
    /// a row above the text, and rounds where the text stands to a whole point,
    /// so this asks it rather than working that out.
    private static func baseline(of font: NSFont, in paragraph: NSParagraphStyle) -> CGFloat {
        let storage = NSTextStorage(string: "0\n", attributes: [.font: font, .paragraphStyle: paragraph])
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 1e7, height: 1e7))
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        return layoutManager.location(forGlyphAt: 0).y
    }

    /// The measures worked out so far. There are only as many as the fonts and
    /// sizes someone has tried.
    private static let known = Mutex<[CodeFont: DiffMetrics]>([:])

    static func of(_ codeFont: CodeFont) -> DiffMetrics {
        known.withLock { known in
            if let metrics = known[codeFont] { return metrics }
            let metrics = DiffMetrics(codeFont)
            known[codeFont] = metrics
            return metrics
        }
    }

    /// The measures of the font in use.
    static var current: DiffMetrics {
        of(CodeFont.current)
    }
}
