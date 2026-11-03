import AppKit
import GitCore

/// Draws the background of each line across the full width of the view, which
/// a background color in the text can't do: it would stop where the text does.
nonisolated final class DiffLayoutManager: NSLayoutManager, @unchecked Sendable {
    weak var document: DiffDocument?
    /// Where the text being searched for shows, in order.
    var matches: [NSRange] = []
    /// Which of the matches the search is at.
    var currentMatch: Int?

    override func drawBackground(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        if let document, let context = NSGraphicsContext.current?.cgContext {
            enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, glyphs, _ in
                let line = document.lines[document.lineIndex(atCharacter: self.characterIndexForGlyph(at: glyphs.location))]
                guard let color = DiffStyle.background(line.kind) else { return }
                // A fragment is as wide as the text container, which is much
                // wider than the view, and drawing stops at the view's edge.
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: 0, y: rect.minY + origin.y, width: rect.maxX + origin.x, height: rect.height))
            }
            drawMatches(forGlyphRange: glyphs, at: origin, in: context)
        }
        // This draws the selection, over the backgrounds.
        super.drawBackground(forGlyphRange: glyphs, at: origin)
    }

    /// Fills behind the matches among the lines being drawn, so that only those
    /// take any time, however many matches the text has.
    private func drawMatches(forGlyphRange glyphs: NSRange, at origin: NSPoint, in context: CGContext) {
        guard !matches.isEmpty, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var index = firstMatch(endingAfter: characters.location)
        while index < matches.count, matches[index].location < characters.upperBound {
            let color = index == currentMatch ? DiffStyle.currentMatchBackground : DiffStyle.matchBackground
            context.setFillColor(color.cgColor)
            enumerateEnclosingRects(
                forGlyphRange: glyphRange(forCharacterRange: matches[index], actualCharacterRange: nil),
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                context.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
            }
            index += 1
        }
    }

    private func firstMatch(endingAfter character: Int) -> Int {
        var low = 0
        var high = matches.count
        while low < high {
            let middle = (low + high) / 2
            if matches[middle].upperBound <= character { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
