import AppKit
import GitCore
import Testing
import ThemeUI
@testable import DiffUI

/// The code font chosen in Settings › Appearance (decision 73), and what it
/// comes to in a diff. No test changes the font in use, since every diff in the
/// process is built in it: each asks for the font it wants.
@Suite(.timeLimit(.minutes(1)))
struct DiffMetricsTests {
    /// Menlo comes with macOS, so it's there to stand for a font someone chose.
    let menlo = CodeFont(family: "Menlo", size: 16)

    func patch(lines: Int = 3) throws -> FilePatch {
        try PatchParser.parse(Array(("@@ -0,0 +1,\(lines) @@\n" + (1...lines).map { "+line \($0)\n" }.joined()).utf8))
    }

    func text(of controller: DiffTextController) -> NSTextView {
        controller.scrollView.documentView as! NSTextView
    }

    @Test func theStandardFontKeepsTheRowsDiffsHad() {
        let metrics = DiffMetrics.of(.standard)
        #expect(metrics.font == NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        #expect(metrics.boldFont == NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold))
        #expect(metrics.lineHeight == 17)
        #expect(metrics.numberFont.pointSize == 11)
        #expect(DiffMetrics.current.codeFont == .standard)
        // The same font's measures are worked out once.
        #expect(DiffMetrics.of(.standard) === metrics)
    }

    @Test func aLargerSizeMakesTallerRowsAndWiderColumns() {
        var last: DiffMetrics?
        for size in CodeFont.sizes {
            let metrics = DiffMetrics.of(CodeFont(size: size))
            #expect(metrics.font.pointSize == CGFloat(size))
            // Rows start on whole points, and leave room around the font's own line.
            #expect(metrics.lineHeight == metrics.lineHeight.rounded())
            #expect(metrics.lineHeight > metrics.font.ascender - metrics.font.descender)
            // The text stands inside its row, with its descenders above the bottom.
            #expect(metrics.baseline >= metrics.font.ascender)
            #expect(metrics.baseline - metrics.font.descender <= metrics.lineHeight + 0.5)
            #expect(metrics.numberFont.pointSize == CGFloat(size) - 1)
            if let last {
                #expect(metrics.lineHeight > last.lineHeight)
                #expect(metrics.columnWidth > last.columnWidth)
                #expect(metrics.digitWidth > last.digitWidth)
            }
            last = metrics
        }
    }

    @Test func aFamilyGivesItsRegularAndBoldFaces() {
        #expect(menlo.font().fontName == "Menlo-Regular")
        #expect(menlo.font(isBold: true).fontName == "Menlo-Bold")
        #expect(menlo.font().pointSize == 16)
        #expect(CodeFont.isInstalled("Menlo"))

        // A family that's gone gives the system's font rather than nothing.
        let missing = CodeFont(family: "No Such Family", size: 14)
        #expect(!CodeFont.isInstalled("No Such Family"))
        #expect(missing.font() == NSFont.monospacedSystemFont(ofSize: 14, weight: .regular))
        #expect(missing.font(isBold: true) == NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold))
    }

    @Test func whatsStoredIsTheFontUnlessItCantBe() throws {
        let name = "DiffMetricsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(CodeFont.stored(in: defaults) == .standard)

        defaults.set("Menlo", forKey: CodeFont.familyKey)
        defaults.set(14.0, forKey: CodeFont.sizeKey)
        #expect(CodeFont.stored(in: defaults) == CodeFont(family: "Menlo", size: 14))

        // A family that was removed, and sizes from outside Settings.
        defaults.set("No Such Family", forKey: CodeFont.familyKey)
        defaults.set(64.0, forKey: CodeFont.sizeKey)
        #expect(CodeFont.stored(in: defaults) == CodeFont(family: nil, size: 20))
        defaults.set(2.0, forKey: CodeFont.sizeKey)
        #expect(CodeFont.stored(in: defaults).size == 11)
        // A size in between is kept, as whole points, and Settings lists it.
        defaults.set(16.6, forKey: CodeFont.sizeKey)
        #expect(CodeFont.stored(in: defaults).size == 17)
        #expect(CodeFont.usable(size: 12) == 12)
    }

    @MainActor @Test func settingsOffersFamiliesOfOneWidth() {
        let families = CodeFont.installedFamilies()
        #expect(families.contains("Menlo"))
        // Not a font whose letters differ in width, and not the system's own
        // font twice.
        #expect(!families.contains("Helvetica"))
        #expect(!families.contains(CodeFont.systemFamilyTitle))
        #expect(families == families.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(CodeFont.sizes.contains(CodeFont.defaultSize))
    }

    @Test func aDocumentIsBuiltInTheFontAsked() throws {
        let metrics = DiffMetrics.of(menlo)
        let document = DiffTextBuilder.build(try patch(lines: 40), metrics: metrics)
        #expect(document.font == menlo)
        #expect(document.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == metrics.font)

        // Every line is a row of the font's height, and its text stands where
        // the line numbers are drawn.
        let layoutManager = document.layoutManager
        for row in [0, 1, 17, 39] {
            let glyph = layoutManager.glyphIndexForCharacter(at: document.lineStarts[row])
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            #expect(fragment.minY == CGFloat(row) * metrics.lineHeight)
            #expect(fragment.height == metrics.lineHeight)
            #expect(layoutManager.location(forGlyphAt: glyph).y == metrics.baseline)
        }

        // The font in use is what a document is in when nothing else is asked.
        #expect(DiffTextBuilder.build(try patch()).font == CodeFont.current)
        #expect(DiffTextBuilder.document(forShort: try patch(), in: menlo).font == menlo)
    }

    @Test func aConflictsSidesAreNamedInTheFontsBoldFace() throws {
        let sides = ConflictSides(
            ours: .init(name: "main", detail: "a", keepTitle: "Keep main's", keptTitle: "Kept main's"),
            theirs: .init(name: "origin/main", detail: "b", keepTitle: "Keep theirs", keptTitle: "Kept theirs")
        )
        let file = ConflictedFile.parse(Array("top\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> origin/main\nend\n".utf8))
        let metrics = DiffMetrics.of(menlo)
        let document = DiffTextBuilder.build(file, choices: [:], sides: sides, metrics: metrics)
        #expect(document.font == menlo)
        let label = (document.storage.string as NSString).range(of: "main · a")
        #expect(document.storage.attribute(.font, at: label.location, effectiveRange: nil) as? NSFont == metrics.boldFont)

        // Its bands are two rows of that font tall.
        let controller = DiffTextController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        controller.view.layoutSubtreeIfNeeded()
        controller.resolveConflict = { _ in }
        controller.show(document)
        let bar = try #require(controller.view.subviews.compactMap { $0 as? ConflictBar }.first { !$0.isHidden })
        #expect(bar.frame.height == 2 * metrics.lineHeight)
        let textView = text(of: controller)
        #expect(controller.view.convert(bar.frame, to: textView).minY == textView.textContainerOrigin.y + metrics.lineHeight)
    }

    /// A diff that's built again in another font stays at the line it was at,
    /// rather than the same distance down, which would be another line.
    @Test func aCopyInAnotherFontStaysAtTheSameLine() throws {
        let patch = try patch(lines: 500)
        let standard = DiffMetrics.of(.standard)
        let large = DiffMetrics.of(menlo)
        let controller = DiffTextController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        controller.view.layoutSubtreeIfNeeded()
        controller.show(DiffTextBuilder.build(patch, metrics: standard))
        let thickness = controller.scrollView.frame.minX
        #expect(controller.scrollView.verticalLineScroll == standard.lineHeight)

        let clip = controller.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 120 * standard.lineHeight))
        controller.show(DiffTextBuilder.build(patch, metrics: large), keepingPosition: true)
        #expect(clip.bounds.minY == 120 * large.lineHeight)
        #expect(controller.scrollView.verticalLineScroll == large.lineHeight)
        #expect(controller.scrollView.horizontalLineScroll == large.columnWidth * 4)
        #expect(text(of: controller).frame.height >= 501 * large.lineHeight)

        // The line numbers are larger too, so they take more room.
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.scrollView.frame.minX > thickness)
        #expect(DiffTextController.height(lines: 6, in: menlo) == 6 * large.lineHeight + 8)
    }

    /// A hunk's button fits on its band in the smallest font, with a point of
    /// the band above and below it.
    @Test func aHunksButtonFitsOnItsBandInTheSmallestFont() throws {
        let smallest = DiffMetrics.of(CodeFont(size: try #require(CodeFont.sizes.first)))
        let controller = DiffTextController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        controller.view.layoutSubtreeIfNeeded()
        controller.discardHunk = { _ in }
        controller.show(DiffTextBuilder.build(try patch(lines: 30), metrics: smallest))
        controller.showHunkButton(atTextY: text(of: controller).textContainerOrigin.y + smallest.lineHeight * 3)
        #expect(!controller.hunkButton.isHidden)
        #expect(controller.hunkButton.frame.height == smallest.lineHeight - 2)

        controller.show(DiffTextBuilder.build(try patch(lines: 30), metrics: .of(menlo)))
        #expect(controller.hunkButton.size.height == 15)
    }
}
