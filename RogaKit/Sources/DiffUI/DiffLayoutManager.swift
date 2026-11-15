import AppKit
import GitCore

/// Draws the background of each line across the full width of the view, which
/// a background color in the text can't do: it would stop where the text does.
/// It also draws the line under each hunk's band, whose rows are empty in the
/// text. What the band says is drawn over the gutter and the text, by `HunkHeaders`.
nonisolated final class DiffLayoutManager: NSLayoutManager, @unchecked Sendable {
    weak var document: DiffDocument?
    /// Where the text being searched for shows, in order.
    var matches: [NSRange] = []
    /// Which of the matches the search is at.
    var currentMatch: Int?

    override func drawBackground(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        var bands: [HunkBand] = []
        if let document, let context = NSGraphicsContext.current?.cgContext {
            enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, glyphs, _ in
                let row = document.lineIndex(atCharacter: self.characterIndexForGlyph(at: glyphs.location))
                if document.lines[row].kind == .hunkHeader, let band = document.hunkBand(atRow: row), bands.last != band {
                    bands.append(band)
                }
                guard let color = document.background(ofRow: row) else { return }
                // A fragment is as wide as the text container, which is much
                // wider than the view, and drawing stops at the view's edge.
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: 0, y: rect.minY + origin.y, width: rect.maxX + origin.x, height: rect.height))
            }
            drawChangedWords(of: document, forGlyphRange: glyphs, at: origin, in: context)
            enumerateRects(of: matches, forGlyphRange: glyphs, at: origin) { index, rect in
                let color = index == self.currentMatch ? DiffStyle.currentMatchBackground : DiffStyle.matchBackground
                context.setFillColor(color.cgColor)
                context.fill(rect)
            }
        }
        // This draws the selection, over the backgrounds.
        super.drawBackground(forGlyphRange: glyphs, at: origin)
        if let document {
            for band in bands {
                draw(band, of: document, at: origin)
            }
        }
    }

    /// Draws the line at the bottom of a hunk's band, across the full width of the view.
    private func draw(_ band: HunkBand, of document: DiffDocument, at origin: NSPoint) {
        let metrics = document.metrics
        let top = origin.y + CGFloat(band.row) * metrics.lineHeight
        let content = HunkBand.content(lineHeight: metrics.lineHeight)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: top + content.top + content.height - 1, width: 1e7, height: 1).fill(using: .sourceOver)
    }

    private func drawChangedWords(of document: DiffDocument, forGlyphRange glyphs: NSRange, at origin: NSPoint, in context: CGContext) {
        enumerateRects(of: document.changedWords, forGlyphRange: glyphs, at: origin) { index, rect in
            let line = document.lines[document.lineIndex(atCharacter: document.changedWords[index].location)]
            guard let color = DiffStyle.changedWordBackground(line.kind) else { return }
            context.setFillColor(color.cgColor)
            let radius = DiffStyle.changedWordCornerRadius
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
    }

    /// Goes through those of some sorted ranges that are among the lines being
    /// drawn, so that only those take any time, however many ranges there are.
    private func enumerateRects(of ranges: [NSRange], forGlyphRange glyphs: NSRange, at origin: NSPoint, body: @escaping (Int, CGRect) -> Void) {
        guard !ranges.isEmpty, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var index = Self.firstRange(of: ranges, endingAfter: characters.location)
        while index < ranges.count, ranges[index].location < characters.upperBound {
            enumerateEnclosingRects(
                forGlyphRange: glyphRange(forCharacterRange: ranges[index], actualCharacterRange: nil),
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                body(index, rect.offsetBy(dx: origin.x, dy: origin.y))
            }
            index += 1
        }
    }

    private static func firstRange(of ranges: [NSRange], endingAfter character: Int) -> Int {
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if ranges[middle].upperBound <= character { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
