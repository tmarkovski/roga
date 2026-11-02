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
