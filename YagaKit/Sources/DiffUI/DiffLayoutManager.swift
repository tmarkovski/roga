import AppKit
import GitCore

/// Draws the background of each line across the full width of the view, which
/// a background color in the text can't do: it would stop where the text does.
nonisolated final class DiffLayoutManager: NSLayoutManager, @unchecked Sendable {
    weak var document: DiffDocument?

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
        }
        // This draws the selection, over the backgrounds.
        super.drawBackground(forGlyphRange: glyphs, at: origin)
    }
}
