import AppKit
import GitCore
import Testing
@testable import DiffUI

@Suite(.timeLimit(.minutes(1)))
struct DiffTextControllerTests {
    func document(_ text: String = "@@ -1 +1 @@\n-old\n+new\n") throws -> DiffDocument {
        DiffTextBuilder.build(try PatchParser.parse(Array(text.utf8)))
    }

    func text(of controller: DiffTextController) -> NSTextView {
        controller.scrollView.documentView as! NSTextView
    }

    func longDocument() throws -> DiffDocument {
        try document("@@ -0,0 +1,500 @@\n" + (1...500).map { "+line \($0)\n" }.joined())
    }

    @Test func bringsTheCurrentMatchIntoView() throws {
        let document = try longDocument()
        let controller = DiffTextController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        controller.view.layoutSubtreeIfNeeded()
        controller.show(document)

        let matches = document.ranges(of: "line 450")
        controller.showMatches(matches, current: 0)
        #expect(controller.scrollView.contentView.bounds.minY == 0)
        controller.scrollToCurrentMatch()

        let rows = controller.scrollView.contentView.bounds.minY / DiffMetrics.current.lineHeight
        #expect((430...451).contains(Int(rows)))
    }

    /// A sample of a diff, as in Settings, is only for looking at.
    @Test func aPictureCantBeSelectedOrScrolled() throws {
        let controller = DiffTextController()
        #expect(text(of: controller).isSelectable)
        #expect(controller.scrollView.hasVerticalScroller)

        controller.isPicture = true
        // Showing a document sets the text view up again.
        controller.show(try document())
        #expect(!text(of: controller).isSelectable)
        #expect(!controller.scrollView.hasVerticalScroller)
        #expect(!controller.scrollView.hasHorizontalScroller)
        // It's given the height that shows all of its lines: three rows here.
        #expect(DiffTextController.height(lines: 3) == 3 * DiffMetrics.current.lineHeight + 8)
    }

    @Test func selectsTheCurrentMatchWhenTheSearchEnds() throws {
        let document = try longDocument()
        let controller = DiffTextController()
        controller.show(document)
        let matches = document.ranges(of: "line 3")
        controller.showMatches(matches, current: 1)
        controller.endFind()
        #expect(text(of: controller).selectedRange() == matches[1])

        // A search that found nothing leaves the selection alone.
        controller.showMatches([], current: nil)
        controller.endFind()
        #expect(text(of: controller).selectedRange() == matches[1])
    }

    @Test func handsADocumentToANewController() throws {
        // What happens when a window goes to another worktree and back.
        let document = try document()
        var first: DiffTextController? = DiffTextController()
        first?.show(document)
        let second = DiffTextController()
        second.show(document)
        #expect(text(of: second).string == "\n\nold\nnew\n")

        // A text view going away can take the text with it.
        autoreleasepool { first = nil }
        #expect(first == nil)
        #expect(text(of: second).string == "\n\nold\nnew\n")
        #expect(document.container.textView === text(of: second))
    }

    @Test func keepsADocumentAfterTheControllerShowingItGoesAway() throws {
        let document = try document()
        autoreleasepool {
            let first = DiffTextController()
            first.show(document)
        }
        let second = DiffTextController()
        second.show(document)
        #expect(text(of: second).string == "\n\nold\nnew\n")
    }

    /// While an agent works on a file's conflicts, each one in view has what its
    /// owner made around the whole section, from its band to its last side and
    /// from the line numbers to the far edge (decision 68).
    @Test func putsAnOutlineAroundEachConflictWhileAnAgentWorks() throws {
        let sides = ConflictSides(
            ours: .init(name: "main", detail: "a", keepTitle: "Keep main's", keptTitle: "Kept main's"),
            theirs: .init(name: "origin/main", detail: "b", keepTitle: "Keep theirs", keptTitle: "Kept theirs")
        )
        let file = ConflictedFile.parse(Array("top\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> origin/main\nend\n".utf8))
        let controller = DiffTextController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        controller.view.layoutSubtreeIfNeeded()
        controller.show(DiffTextBuilder.build(file, choices: [:], sides: sides))
        let textView = text(of: controller)
        let others = controller.view.subviews.count

        final class Outline: NSView {}
        controller.makeConflictOutline = { Outline() }
        let outlines = controller.view.subviews.compactMap { $0 as? Outline }
        #expect(outlines.count == 1)
        let outline = try #require(outlines.first)
        #expect(!outline.isHidden)
        // It starts under the gap above the band, where the band does.
        let gap = HunkBand.gap(lineHeight: DiffMetrics.current.lineHeight)
        #expect(outline.frame.height == 6 * DiffMetrics.current.lineHeight - gap)
        #expect(controller.view.convert(outline.frame, to: textView).minY == textView.textContainerOrigin.y + DiffMetrics.current.lineHeight + gap)
        #expect(outline.frame.minX == DiffTextController.outlineInset)
        #expect(outline.frame.maxX == controller.view.bounds.width - DiffTextController.outlineInset)
        // The text starts after the line numbers, which the outline has to go around.
        #expect(outline.frame.minX < controller.scrollView.frame.minX)

        controller.makeConflictOutline = nil
        #expect(controller.view.subviews.count == others)
    }

    private func conflicted() -> (controller: DiffTextController, file: ConflictedFile, sides: ConflictSides) {
        let sides = ConflictSides(
            ours: .init(name: "main", detail: "a", keepTitle: "Keep main's", keptTitle: "Kept main's"),
            theirs: .init(name: "origin/main", detail: "b", keepTitle: "Keep theirs", keptTitle: "Kept theirs")
        )
        let file = ConflictedFile.parse(Array("top\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> origin/main\nend\n".utf8))
        let controller = DiffTextController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        controller.view.layoutSubtreeIfNeeded()
        return (controller, file, sides)
    }

    private func bar(of controller: DiffTextController) throws -> ConflictBar {
        try #require(controller.view.subviews.compactMap { $0 as? ConflictBar }.first { !$0.isHidden })
    }

    private func titles(of bar: ConflictBar) -> [String] {
        bar.subviews.compactMap { $0 as? NSButton }.map(\.title)
    }

    private func label(of bar: ConflictBar) throws -> String {
        try #require(bar.subviews.compactMap { $0 as? NSTextField }.first).stringValue
    }

    /// A band is as tall as the canvas draws it, with room around its buttons,
    /// and it starts on its row. It's laid out as a hunk's band is: its buttons
    /// are under the gap that sets it apart, at the edge, and its label is at the
    /// view's left edge, after the icon, rather than where the text starts.
    @Test func aConflictsBandIsTallerThanARow() throws {
        let (controller, file, sides) = conflicted()
        controller.resolveConflict = { _ in }
        controller.show(DiffTextBuilder.build(file, choices: [:], sides: sides))
        let bar = try bar(of: controller)
        let textView = text(of: controller)
        #expect(bar.frame.height == 34)
        #expect(controller.view.convert(bar.frame, to: textView).minY == textView.textContainerOrigin.y + DiffMetrics.current.lineHeight)
        #expect(bar.frame.minX == 0)
        #expect(titles(of: bar) == ["Keep main's", "Keep theirs", "Keep Both", "Edit…"])
        #expect(try label(of: bar) == "Conflict 1 of 1")
        let content = HunkBand.content(lineHeight: DiffMetrics.current.lineHeight)
        let buttons = bar.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.allSatisfy { $0.frame.height == 22 && $0.frame.minY == content.top + (content.height - 22) / 2 })
        #expect(try #require(buttons.last).frame.maxX == bar.bounds.width - 6)
        let field = try #require(bar.subviews.compactMap { $0 as? NSTextField }.first)
        #expect(field.frame.minX < controller.scrollView.frame.minX)
        #expect(field.frame.minX > DiffStyle.bandInset)
    }

    /// The gap above a band shows what's around it, as a hunk's does, so the band's
    /// rows have no color of their own.
    @Test func aConflictsBandHasNoBackground() throws {
        let (_, file, sides) = conflicted()
        let document = DiffTextBuilder.build(file, choices: [:], sides: sides)
        let band = try #require(document.conflictBands.first)
        #expect(document.background(ofRow: band.row) == nil)
        #expect(document.background(ofRow: band.row + 1) == nil)
    }

    /// An overlay scroller draws over the text's right edge while the text scrolls,
    /// so a band's buttons stop short of it, and the band still runs under it.
    @Test func aConflictsButtonsStayClearOfAnOverlayScroller() throws {
        let (controller, _, sides) = conflicted()
        let long = "top\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> origin/main\n" + (1...40).map { "line \($0)\n" }.joined()
        controller.scrollView.scrollerStyle = .overlay
        controller.resolveConflict = { _ in }
        controller.show(DiffTextBuilder.build(ConflictedFile.parse(Array(long.utf8)), choices: [:], sides: sides))
        controller.scrollView.tile()
        controller.updateConflictBars()
        let scroller = try #require(controller.scrollView.verticalScroller)
        #expect(!scroller.isHidden)
        let edge = controller.view.convert(scroller.frame, from: controller.scrollView).minX
        let bar = try bar(of: controller)
        let last = try #require(bar.subviews.compactMap { $0 as? NSButton }.last)
        #expect(bar.convert(last.frame, to: controller.view).maxX == edge - 6)
        #expect(bar.frame.maxX > edge)
    }

    @Test func aResolvedBandSaysWhatItKept() throws {
        let (controller, file, sides) = conflicted()
        controller.resolveConflict = { _ in }
        controller.show(DiffTextBuilder.build(file, choices: [0: .ours], sides: sides))
        let bar = try bar(of: controller)
        #expect(try label(of: bar) == "Kept main's  Conflict 1 of 1")
        #expect(titles(of: bar) == ["Show Sides", "Undo"])
    }

    /// While an agent works there's nothing to press, and the band still says
    /// which conflict it is.
    @Test func aBandKeepsItsLabelWhenItCantBeResolved() throws {
        let (controller, file, sides) = conflicted()
        controller.show(DiffTextBuilder.build(file, choices: [:], sides: sides))
        let bar = try bar(of: controller)
        #expect(try label(of: bar) == "Conflict 1 of 1")
        #expect(titles(of: bar).isEmpty)
    }

    /// What's on a band isn't text, whichever way the pointer got there.
    @Test func theTextViewLeavesTheCursorAloneOverABand() throws {
        let (controller, file, sides) = conflicted()
        controller.resolveConflict = { _ in }
        controller.show(DiffTextBuilder.build(file, choices: [:], sides: sides))
        let window = NSWindow(contentRect: controller.view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        let bar = try bar(of: controller)
        let textView = text(of: controller)
        func moved(to point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: .mouseMoved, location: controller.view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            ))
        }
        NSCursor.iBeam.set()
        textView.mouseMoved(with: try moved(to: NSPoint(x: bar.frame.maxX - 20, y: bar.frame.midY)))
        #expect(NSCursor.current == .arrow)
    }

    @Test func goesBackToADocumentItShowedBefore() throws {
        let one = try document()
        let two = try document("@@ -1 +1,2 @@\n a\n+b\n")
        let controller = DiffTextController()
        controller.show(one)
        controller.show(two)
        #expect(text(of: controller).string == "\n\na\nb\n")
        controller.show(one)
        #expect(text(of: controller).string == "\n\nold\nnew\n")
    }

    @Test func keepsItsPlaceInANewerCopyOfADocument() throws {
        let lines = (1...200).map { " line \($0)\n" }.joined()
        let one = try document("@@ -1,200 +1,200 @@\n" + lines)
        let two = try document("@@ -1,200 +1,200 @@\n" + lines)
        let three = try document("@@ -1,200 +1,200 @@\n" + lines)
        let controller = DiffTextController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        controller.view.layoutSubtreeIfNeeded()
        controller.show(one)
        let textView = text(of: controller)
        textView.scroll(NSPoint(x: 0, y: 300))
        let position = textView.visibleRect.origin

        controller.show(two, keepingPosition: true)
        #expect(textView.visibleRect.origin == position)
        controller.show(three)
        #expect(textView.visibleRect.origin.y == 0)
    }

    // MARK: The whole file (decision 74)

    /// A file of 200 lines whose 50th and 150th changed, as git prints the
    /// whole of it and as it prints its hunks.
    func fileLine(_ number: Int) -> String {
        number == 50 || number == 150 ? "-line old\n+line new\n" : " line \(number)\n"
    }

    func wholeFile() throws -> DiffDocument {
        let text = "@@ -1,200 +1,200 @@\n" + (1...200).map(fileLine).joined()
        return DiffTextBuilder.build(try PatchParser.parse(Array(text.utf8)), layout: .inline)
    }

    func hunksOfThatFile() throws -> DiffDocument {
        try document([47, 147].map { start in "@@ -\(start),7 +\(start),7 @@\n" + (start..<start + 7).map(fileLine).joined() }.joined())
    }

    @Test func aWholeFileStartsAFewLinesAboveItsFirstChange() throws {
        let lineHeight = DiffMetrics.current.lineHeight
        let controller = controller(showing: try wholeFile())
        let textView = text(of: controller)
        // Line 50 is on the 50th row, and lines 47 to 49 show above it.
        #expect(textView.visibleRect.origin.y == 4 + 46 * lineHeight)

        // Hunks start at the top, and so does a whole file that changes near its top.
        controller.show(try hunksOfThatFile())
        #expect(textView.visibleRect.origin.y == 0)
        let early = "@@ -1,200 +1,200 @@\n line 1\n-line old\n+line new\n" + (3...200).map { " line \($0)\n" }.joined()
        controller.show(DiffTextBuilder.build(try PatchParser.parse(Array(early.utf8)), layout: .inline))
        #expect(textView.visibleRect.origin.y == 0)

        // A newer copy of the whole file stays where it was scrolled to.
        controller.show(try wholeFile())
        textView.scroll(NSPoint(x: 0, y: 300))
        controller.show(try wholeFile(), keepingPosition: true)
        #expect(textView.visibleRect.origin.y == 300)
    }

    /// The view can be asked to show a file before SwiftUI has given it a size.
    @Test func aWholeFileGoesToItsFirstChangeOnceTheViewHasASize() throws {
        let controller = DiffTextController()
        controller.show(try wholeFile())
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        controller.view.layoutSubtreeIfNeeded()
        #expect(text(of: controller).visibleRect.origin.y == 4 + 46 * DiffMetrics.current.lineHeight)

        // It only goes there once, and not each time the view changes size.
        text(of: controller).scroll(NSPoint(x: 0, y: 0))
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        controller.view.layoutSubtreeIfNeeded()
        #expect(text(of: controller).visibleRect.origin.y == 0)
    }

    @Test func staysAtTheSameLineOfTheFileWhenTheLayoutChanges() throws {
        let lineHeight = DiffMetrics.current.lineHeight
        // Four rows tall, so that the hunks' 18 rows have room to scroll.
        let controller = DiffTextController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 4 * lineHeight)
        controller.view.layoutSubtreeIfNeeded()
        controller.show(try hunksOfThatFile())
        let textView = text(of: controller)

        // The second hunk's band is at the top, on rows 10 and 11, with line
        // 147 under it. In the whole file, line 147 stays two rows down.
        let secondBand = try hunksOfThatFile().hunkHeaders[1]
        #expect(secondBand == 10)
        textView.scroll(NSPoint(x: 0, y: 4 + 10 * lineHeight))
        controller.show(try wholeFile(), keepingPosition: true)
        #expect(textView.visibleRect.origin.y == 4 + 145 * lineHeight)

        // Line 146 isn't in the hunks, so the hunk after it starts at the top.
        controller.show(try hunksOfThatFile(), keepingPosition: true)
        #expect(textView.visibleRect.origin.y == 4 + 10 * lineHeight)

        // A line that's in both stays exactly where it was, here with 5 points
        // of it cut off at the top: line 148, the second under the band.
        controller.show(try wholeFile(), keepingPosition: true)
        textView.scroll(NSPoint(x: 0, y: 4 + 148 * lineHeight + 5))
        controller.show(try hunksOfThatFile(), keepingPosition: true)
        #expect(textView.visibleRect.origin.y == 4 + 13 * lineHeight + 5)

        // A hunk's first line at the top brings the hunk's whole band with it,
        // rather than leaving it just out of view: line 147, whole or cut off.
        for cutOff in [0.0, 5.0] {
            controller.show(try wholeFile(), keepingPosition: true)
            textView.scroll(NSPoint(x: 0, y: 4 + 147 * lineHeight + cutOff))
            controller.show(try hunksOfThatFile(), keepingPosition: true)
            #expect(textView.visibleRect.origin.y == 4 + 10 * lineHeight)
        }

        // The first hunk at the top of the hunks is the top of them.
        controller.show(try wholeFile(), keepingPosition: true)
        textView.scroll(NSPoint(x: 0, y: 4 + 20 * lineHeight))
        controller.show(try hunksOfThatFile(), keepingPosition: true)
        #expect(textView.visibleRect.origin.y == 0)
    }

    @Test func usesTextKit1() throws {
        // Asking for the layout manager of a text view on TextKit 2 quietly
        // moves it to TextKit 1, so this looks at the other one first.
        let controller = DiffTextController()
        #expect(text(of: controller).textLayoutManager == nil)
        controller.show(try document())
        #expect(text(of: controller).textLayoutManager == nil)
    }

    @Test func cantBeEditedWhicheverDocumentItShows() throws {
        // TextKit keeps these with the layout manager, and each document has
        // its own.
        let controller = DiffTextController()
        for document in [try document(), try document("@@ -1 +1,2 @@\n a\n+b\n")] {
            controller.show(document)
            let view = text(of: controller)
            #expect(!view.isEditable)
            #expect(view.isSelectable)
            #expect(!view.isRichText)
            #expect(!view.drawsBackground)
        }
    }

    @Test func forgetsTheSelectionWithTheText() throws {
        let long = try document("@@ -1,3 +1,3 @@\n aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n-b\n+c\n d\n")
        let controller = DiffTextController()
        controller.show(long)
        text(of: controller).setSelectedRange(NSRange(location: 30, length: 10))
        controller.show(try document())
        #expect(text(of: controller).selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func knowsHowTallTheTextIs() throws {
        // Every row, without having drawn any of them.
        let lines = (0..<2000).map { "+line \($0)\n" }.joined()
        let controller = DiffTextController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        controller.show(try document("@@ -0,0 +1,2000 @@\n" + lines))
        let rows = CGFloat(2000 + HunkBand.rowCount) * DiffMetrics.current.lineHeight
        // The last line's newline makes an empty row after it, and there's a
        // little space above and below.
        #expect(abs(text(of: controller).frame.height - rows) <= DiffMetrics.current.lineHeight + 8)
    }

    // MARK: Hunks

    /// Two hunks of 20 lines each, which is taller than the view that's used here.
    func twoHunks() throws -> DiffDocument {
        let hunk = { (start: Int) in "@@ -\(start),20 +\(start),20 @@\n" + (0..<20).map { " line \(start + $0)\n" }.joined() }
        return try document(hunk(1) + hunk(40))
    }

    func controller(showing document: DiffDocument) -> DiffTextController {
        let controller = DiffTextController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        controller.view.layoutSubtreeIfNeeded()
        controller.show(document)
        return controller
    }

    @Test func findsTheHunkOfARow() throws {
        let document = try twoHunks()
        // Each band takes two rows, so the second starts a row after its
        // header's place in the patch.
        #expect(document.hunkHeaders == [0, 22])
        #expect(document.hunkBands.map(\.line) == [0, 21])
        #expect(document.hunkHeader(atRow: 0) == 0)
        #expect(document.hunkHeader(atRow: 21) == 0)
        #expect(document.hunkHeader(atRow: 22) == 22)
        #expect(document.hunkHeader(atRow: 43) == 22)
        #expect(document.hunkBand(atRow: 43)?.line == 21)
        #expect(document.hunkHeader(atRow: 44) == nil)
        #expect(document.hunkHeader(atRow: -1) == nil)
    }

    @Test func aRowIsWhereTheTextIsWithoutAskingForLayout() throws {
        // The button works out where a band is from its row, which is only right
        // while every line is one row of the same height.
        let document = try twoHunks()
        let controller = controller(showing: document)
        let text = text(of: controller)
        for row in document.hunkHeaders {
            let glyph = document.layoutManager.glyphIndexForCharacter(at: document.lineStarts[row])
            let fragment = document.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let top = text.textContainerOrigin.y + fragment.minY
            #expect(top == text.textContainerOrigin.y + CGFloat(row) * DiffMetrics.current.lineHeight)
            #expect(controller.hunkHeader(atTextY: top + 1) == row)
            #expect(fragment.height == DiffMetrics.current.lineHeight)
        }
    }

    @Test func theButtonShowsOnTheBandOfTheHunkUnderThePointer() throws {
        let controller = controller(showing: try twoHunks())
        // A legacy scroller takes its room from the text, so the edge of what
        // shows is the edge for the buttons. An overlay scroller has its own test.
        controller.scrollView.scrollerStyle = .legacy
        controller.scrollView.tile()
        controller.discardHunk = { _ in }
        let origin = text(of: controller).textContainerOrigin.y
        // A line of the first hunk, with its band in view.
        controller.showHunkButtons(atTextY: origin + DiffMetrics.current.lineHeight * 5)
        #expect(!controller.hunkButton.isHidden)
        #expect(controller.hunkButton.header == 0)
        // It's in the band, under its gap and over its line: the view isn't
        // flipped, and the band is the top two rows.
        let clip = controller.scrollView.contentView
        let visible = controller.view.convert(clip.bounds, from: clip)
        let content = HunkBand.content(lineHeight: DiffMetrics.current.lineHeight)
        let frame = controller.hunkButton.frame
        #expect(abs(frame.midY - (visible.maxY - origin - content.top - (content.height - 1) / 2)) <= 1)
        #expect(frame.height == 22)
        #expect(frame.maxY <= visible.maxY - origin - content.top)
        #expect(frame.minY >= visible.maxY - origin - content.top - content.height)
        #expect(abs(frame.maxX - (visible.maxX - 6)) < 1)
    }

    /// An overlay scroller draws over the text's right edge whenever the text
    /// scrolls or the pointer comes near, so the buttons stop short of it.
    @Test func theButtonsStayClearOfAnOverlayScroller() throws {
        let controller = controller(showing: try twoHunks())
        controller.scrollView.scrollerStyle = .overlay
        controller.scrollView.tile()
        controller.discardHunk = { _ in }
        controller.stageHunk = { _ in }
        let scroller = try #require(controller.scrollView.verticalScroller)
        #expect(!scroller.isHidden)
        controller.showHunkButtons(atTextY: text(of: controller).textContainerOrigin.y + DiffMetrics.current.lineHeight * 5)
        let edge = controller.view.convert(scroller.frame, from: controller.scrollView).minX
        #expect(abs(controller.stagingHunkButton.frame.maxX - (edge - 6)) < 1)
        #expect(controller.hunkButton.frame.maxX < controller.stagingHunkButton.frame.minX)
    }

    /// A hunk's header starts at the view's left edge, over the line numbers, and
    /// stops before its band's buttons while they show.
    @Test func aHunksHeaderStartsAtTheViewsEdge() throws {
        let document = try twoHunks()
        let controller = controller(showing: document)
        controller.discardHunk = { _ in }
        let headers = controller.hunkHeaders.headers
        #expect(headers.map(\.label) == [document.hunkBands[0].label])
        let first = try #require(headers.first)
        #expect(first.box.minX == DiffStyle.bandInset)
        #expect(first.box.minX < controller.scrollView.frame.minX)
        #expect(first.box.height == DiffMetrics.current.lineHeight)

        controller.showHunkButtons(atTextY: text(of: controller).textContainerOrigin.y + DiffMetrics.current.lineHeight * 5)
        let shortened = try #require(controller.hunkHeaders.headers.first)
        #expect(shortened.box.maxX <= controller.hunkButton.frame.minX - 8)
        #expect(shortened.box.minY == first.box.minY)
    }

    @Test func theButtonStaysAtTheEdgeAsTheTextScrollsSideways() throws {
        let long = "@@ -1 +1 @@\n-" + String(repeating: "x", count: 500) + "\n+y\n"
        let controller = controller(showing: try document(long))
        controller.discardHunk = { _ in }
        let origin = text(of: controller).textContainerOrigin.y
        controller.showHunkButtons(atTextY: origin)
        let before = controller.hunkButton.frame
        let clip = controller.scrollView.contentView
        clip.scroll(to: NSPoint(x: 400, y: 0))
        controller.showHunkButtons(atTextY: origin)
        #expect(controller.hunkButton.frame == before)
    }

    @Test func noButtonWhileTheBandIsScrolledAway() throws {
        let document = try twoHunks()
        let controller = controller(showing: document)
        controller.discardHunk = { _ in }
        let text = text(of: controller)
        let clip = controller.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: DiffMetrics.current.lineHeight * 6))
        // A line of the first hunk, whose band has gone off the top.
        controller.showHunkButtons(atTextY: text.textContainerOrigin.y + DiffMetrics.current.lineHeight * 8)
        #expect(controller.hunkButton.isHidden)
    }

    @Test func noButtonOrMenuItemWhenHunksCantBeDiscarded() throws {
        let controller = controller(showing: try twoHunks())
        let y = text(of: controller).textContainerOrigin.y + 1
        controller.showHunkButtons(atTextY: y)
        #expect(controller.hunkButton.isHidden)
        #expect(controller.hunkMenuItems(atTextY: y).isEmpty)
    }

    @Test func noButtonPastTheEndOfThePatch() throws {
        let controller = controller(showing: try document())
        controller.discardHunk = { _ in }
        controller.showHunkButtons(atTextY: 1000)
        #expect(controller.hunkButton.isHidden)
        #expect(controller.hunkMenuItems(atTextY: 1000).isEmpty)
    }

    @Test func theMenuItemTakesTheHunkUnderThePointer() throws {
        let controller = controller(showing: try twoHunks())
        var discarded: [Int] = []
        controller.discardHunk = { discarded.append($0) }
        let y = text(of: controller).textContainerOrigin.y + DiffMetrics.current.lineHeight * 30
        let item = try #require(controller.hunkMenuItems(atTextY: y).first)
        #expect(item.title == "Discard Hunk")
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        #expect(discarded == [21])
    }

    @Test func theButtonTakesTheHunkItsOn() throws {
        let controller = controller(showing: try twoHunks())
        var discarded: [Int] = []
        controller.discardHunk = { discarded.append($0) }
        controller.showHunkButtons(atTextY: text(of: controller).textContainerOrigin.y + 1)
        controller.hunkButton.performClick(nil)
        // The second hunk's band is a row further down than its header is in
        // the patch, and the command gets the header's place in the patch.
        controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: DiffMetrics.current.lineHeight * 22))
        controller.showHunkButtons(atTextY: text(of: controller).textContainerOrigin.y + DiffMetrics.current.lineHeight * 30)
        controller.hunkButton.performClick(nil)
        #expect(discarded == [0, 21])
    }

    @Test func theButtonFitsInABand() {
        let button = HunkButton(.discard)
        #expect(button.size.height <= HunkBand.content(lineHeight: DiffMetrics.current.lineHeight).height - 2)
        #expect(button.size.width > 30)
    }

    @Test func theButtonSaysWhatItDoes() {
        let button = HunkButton(.discard)
        #expect(button.attributedTitle.string == "Discard Hunk")
        #expect(button.accessibilityLabel() == "Discard Hunk")
        // In the color theme's red, as the app's other red buttons are.
        #expect(button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor === HunkButton.red)
        button.command = .unstage
        #expect(button.attributedTitle.string == "Unstage Hunk")
        #expect(button.accessibilityLabel() == "Unstage Hunk")
        #expect(button.toolTip == "Unstage Hunk")
    }

    /// As the words beside a file's path in the diff panel's header do: no
    /// border, and a gray fill only while the pointer is on it.
    @Test func theButtonHasNoBorderAndFillsWithGrayUnderThePointer() throws {
        let button = HunkButton(.discard)
        #expect(button.layer?.borderWidth == 0)
        let rest = try #require(button.layer?.backgroundColor)
        button.isHovering = true
        #expect(button.layer?.borderWidth == 0)
        #expect(button.layer?.backgroundColor != rest)
        button.isHovering = false
        #expect(button.layer?.backgroundColor == rest)
    }

    @Test func stagingGoesAtTheEdgeAndDiscardingBeforeIt() throws {
        let controller = controller(showing: try twoHunks())
        // With a legacy scroller, which leaves the edge clear.
        controller.scrollView.scrollerStyle = .legacy
        controller.scrollView.tile()
        controller.discardHunk = { _ in }
        controller.stageHunk = { _ in }
        controller.showHunkButtons(atTextY: text(of: controller).textContainerOrigin.y + 1)
        let discard = controller.hunkButton
        let stage = controller.stagingHunkButton
        #expect(!discard.isHidden && !stage.isHidden)
        #expect(stage.attributedTitle.string == "Stage Hunk")
        #expect(discard.header == 0 && stage.header == 0)
        let clip = controller.scrollView.contentView
        let visible = controller.view.convert(clip.bounds, from: clip)
        #expect(abs(stage.frame.maxX - (visible.maxX - 6)) < 1)
        #expect(discard.frame.maxX < stage.frame.minX)
        #expect(discard.frame.midY == stage.frame.midY)
    }

    @Test func aStagedDiffOffersOnlyUnstaging() throws {
        let controller = controller(showing: try twoHunks())
        var unstaged: [Int] = []
        controller.unstageHunk = { unstaged.append($0) }
        controller.showHunkButtons(atTextY: text(of: controller).textContainerOrigin.y + 1)
        #expect(controller.hunkButton.isHidden)
        #expect(!controller.stagingHunkButton.isHidden)
        #expect(controller.stagingHunkButton.attributedTitle.string == "Unstage Hunk")
        controller.stagingHunkButton.performClick(nil)
        #expect(unstaged == [0])
        let items = controller.hunkMenuItems(atTextY: text(of: controller).textContainerOrigin.y + 1)
        #expect(items.map(\.title) == ["Unstage Hunk"])
    }

    @Test func theMenuOffersStagingBeforeDiscarding() throws {
        let controller = controller(showing: try twoHunks())
        var staged: [Int] = []
        var discarded: [Int] = []
        controller.discardHunk = { discarded.append($0) }
        controller.stageHunk = { staged.append($0) }
        let y = text(of: controller).textContainerOrigin.y + DiffMetrics.current.lineHeight * 30
        let items = controller.hunkMenuItems(atTextY: y)
        #expect(items.map(\.title) == ["Stage Hunk", "Discard Hunk"])
        for item in items {
            _ = (item.target as? NSObject)?.perform(item.action, with: item)
        }
        #expect(staged == [21])
        #expect(discarded == [21])
    }

    @Test func aButtonThatGoesAwayIsntLeftLookingHovered() throws {
        let controller = controller(showing: try twoHunks())
        controller.discardHunk = { _ in }
        controller.showHunkButtons(atTextY: text(of: controller).textContainerOrigin.y + 1)
        controller.hunkButton.isHovering = true
        // Outside a window, nothing says the pointer is inside, as once it has left.
        controller.show(try twoHunks())
        #expect(controller.hunkButton.isHidden)
        #expect(!controller.hunkButton.isHovering)
    }

    @Test func staysAsWideAsTheViewForShortLines() throws {
        let controller = DiffTextController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        controller.show(try document())
        #expect(text(of: controller).frame.width == controller.scrollView.contentSize.width)
    }

    @Test func growsAsWideAsItsLongestLine() throws {
        let controller = DiffTextController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        controller.show(try document("@@ -0,0 +1 @@\n+" + String(repeating: "x", count: 500) + "\n"))
        #expect(text(of: controller).frame.width >= 500 * DiffMetrics.current.columnWidth)
    }
}
