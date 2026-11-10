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

        let rows = controller.scrollView.contentView.bounds.minY / DiffStyle.lineHeight
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
        #expect(DiffTextController.height(lines: 3) == 3 * DiffStyle.lineHeight + 8)
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
        #expect(text(of: second).string == "@@ -1 +1 @@\nold\nnew\n")

        // A text view going away can take the text with it.
        autoreleasepool { first = nil }
        #expect(first == nil)
        #expect(text(of: second).string == "@@ -1 +1 @@\nold\nnew\n")
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
        #expect(text(of: second).string == "@@ -1 +1 @@\nold\nnew\n")
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
        #expect(outline.frame.height == 6 * DiffStyle.lineHeight)
        #expect(controller.view.convert(outline.frame, to: textView).minY == textView.textContainerOrigin.y + DiffStyle.lineHeight)
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
    /// and it starts on its row.
    @Test func aConflictsBandIsTallerThanARow() throws {
        let (controller, file, sides) = conflicted()
        controller.resolveConflict = { _ in }
        controller.show(DiffTextBuilder.build(file, choices: [:], sides: sides))
        let bar = try bar(of: controller)
        let textView = text(of: controller)
        #expect(bar.frame.height == 34)
        #expect(controller.view.convert(bar.frame, to: textView).minY == textView.textContainerOrigin.y + DiffStyle.lineHeight)
        #expect(bar.frame.minX == 0)
        #expect(titles(of: bar) == ["Keep main's", "Keep theirs", "Keep Both", "Edit…"])
        #expect(try label(of: bar) == "Conflict 1 of 1")
        let buttons = bar.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.allSatisfy { $0.frame.height == 22 && $0.frame.minY == 6 })
        #expect(try #require(buttons.last).frame.maxX == bar.bounds.width - 8)
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
        #expect(text(of: controller).string == "@@ -1 +1,2 @@\na\nb\n")
        controller.show(one)
        #expect(text(of: controller).string == "@@ -1 +1 @@\nold\nnew\n")
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
        let rows = 2001 * DiffStyle.lineHeight
        // The last line's newline makes an empty row after it, and there's a
        // little space above and below.
        #expect(abs(text(of: controller).frame.height - rows) <= DiffStyle.lineHeight + 8)
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
        #expect(document.hunkHeaders == [0, 21])
        #expect(document.hunkHeader(atRow: 0) == 0)
        #expect(document.hunkHeader(atRow: 20) == 0)
        #expect(document.hunkHeader(atRow: 21) == 21)
        #expect(document.hunkHeader(atRow: 41) == 21)
        #expect(document.hunkHeader(atRow: 42) == nil)
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
            #expect(top == text.textContainerOrigin.y + CGFloat(row) * DiffStyle.lineHeight)
            #expect(controller.hunkHeader(atTextY: top + 1) == row)
            #expect(fragment.height == DiffStyle.lineHeight)
        }
    }

    @Test func theButtonShowsOnTheBandOfTheHunkUnderThePointer() throws {
        let controller = controller(showing: try twoHunks())
        controller.discardHunk = { _ in }
        let origin = text(of: controller).textContainerOrigin.y
        // A line of the first hunk, with its band in view.
        controller.showHunkButton(atTextY: origin + DiffStyle.lineHeight * 5)
        #expect(!controller.hunkButton.isHidden)
        #expect(controller.hunkButton.header == 0)
        // It's in the band: the view isn't flipped, and the band is the top row.
        let clip = controller.scrollView.contentView
        let visible = controller.view.convert(clip.bounds, from: clip)
        #expect(abs(controller.hunkButton.frame.midY - (visible.maxY - 4 - DiffStyle.lineHeight / 2)) <= 1)
        #expect(controller.hunkButton.frame.height <= DiffStyle.lineHeight)
        #expect(abs(controller.hunkButton.frame.maxX - (visible.maxX - 6)) < 1)
    }

    @Test func theButtonStaysAtTheEdgeAsTheTextScrollsSideways() throws {
        let long = "@@ -1 +1 @@\n-" + String(repeating: "x", count: 500) + "\n+y\n"
        let controller = controller(showing: try document(long))
        controller.discardHunk = { _ in }
        let origin = text(of: controller).textContainerOrigin.y
        controller.showHunkButton(atTextY: origin)
        let before = controller.hunkButton.frame
        let clip = controller.scrollView.contentView
        clip.scroll(to: NSPoint(x: 400, y: 0))
        controller.showHunkButton(atTextY: origin)
        #expect(controller.hunkButton.frame == before)
    }

    @Test func noButtonWhileTheBandIsScrolledAway() throws {
        let document = try twoHunks()
        let controller = controller(showing: document)
        controller.discardHunk = { _ in }
        let text = text(of: controller)
        let clip = controller.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: DiffStyle.lineHeight * 6))
        // A line of the first hunk, whose band has gone off the top.
        controller.showHunkButton(atTextY: text.textContainerOrigin.y + DiffStyle.lineHeight * 8)
        #expect(controller.hunkButton.isHidden)
    }

    @Test func noButtonOrMenuItemWhenHunksCantBeDiscarded() throws {
        let controller = controller(showing: try twoHunks())
        let y = text(of: controller).textContainerOrigin.y + 1
        controller.showHunkButton(atTextY: y)
        #expect(controller.hunkButton.isHidden)
        #expect(controller.hunkMenuItem(atTextY: y) == nil)
    }

    @Test func noButtonPastTheEndOfThePatch() throws {
        let controller = controller(showing: try document())
        controller.discardHunk = { _ in }
        controller.showHunkButton(atTextY: 1000)
        #expect(controller.hunkButton.isHidden)
        #expect(controller.hunkMenuItem(atTextY: 1000) == nil)
    }

    @Test func theMenuItemTakesTheHunkUnderThePointer() throws {
        let controller = controller(showing: try twoHunks())
        var discarded: [Int] = []
        controller.discardHunk = { discarded.append($0) }
        let y = text(of: controller).textContainerOrigin.y + DiffStyle.lineHeight * 30
        let item = try #require(controller.hunkMenuItem(atTextY: y))
        #expect(item.title == "Discard hunk")
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        #expect(discarded == [21])
    }

    @Test func theButtonTakesTheHunkItsOn() throws {
        let controller = controller(showing: try twoHunks())
        var discarded: [Int] = []
        controller.discardHunk = { discarded.append($0) }
        controller.showHunkButton(atTextY: text(of: controller).textContainerOrigin.y + 1)
        controller.hunkButton.performClick(nil)
        #expect(discarded == [0])
    }

    @Test func theButtonFitsInABand() {
        let button = HunkButton()
        #expect(button.size.height < DiffStyle.lineHeight)
        #expect(button.size.width > 30)
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
        #expect(text(of: controller).frame.width >= 500 * DiffStyle.columnWidth)
    }
}
