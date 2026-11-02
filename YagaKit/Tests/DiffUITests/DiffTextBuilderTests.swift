import AppKit
import GitCore
import Testing
@testable import DiffUI

struct DiffTextBuilderTests {
    func document(_ bytes: [UInt8]) throws -> DiffDocument {
        DiffTextBuilder.build(try PatchParser.parse(bytes))
    }

    func document(_ text: String) throws -> DiffDocument {
        try document(Array(text.utf8))
    }

    func string(_ document: DiffDocument) -> String {
        document.storage.string
    }

    @Test func leavesOutTheSignsAndWhatDescribesTheFile() throws {
        let document = try document("""
            diff --git a/a b/a
            --- a/a
            +++ b/a
            @@ -1,2 +1,2 @@ func main()
             same
            -old
            +new

            """)
        #expect(string(document) == "@@ -1,2 +1,2 @@ func main()\nsame\nold\nnew\n")
    }

    @Test func findsTheLineOfAPositionInTheText() throws {
        let document = try document("@@ -1,2 +1,2 @@\n aa\n-é𝄞\n+c\n")
        let text = string(document) as NSString
        for (index, line) in ["@@ -1,2 +1,2 @@", "aa", "é𝄞", "c"].enumerated() {
            let start = text.range(of: line).location
            #expect(document.lineStarts[index] == start)
            #expect(document.lineIndex(atCharacter: start) == index)
            #expect(document.lineIndex(atCharacter: start + line.utf16.count) == index)
        }
    }

    @Test func givesEachLineOneRowWhateverItHolds() throws {
        // Each of these would otherwise end a row, or the text container.
        let lines = ["a\u{0C}b", "a\rb", "a\u{0B}b", "a\u{85}b", "a\u{2028}b", "a\u{2029}b", "a\u{00}b"]
        let patch = "@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+\($0)\n" }.joined()
        let document = try document(Array(patch.utf8))
        document.layoutManager.ensureLayout(for: document.container)
        var rows = 0
        let glyphs = document.layoutManager.glyphRange(for: document.container)
        document.layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in rows += 1 }
        #expect(rows == lines.count + 1)
        #expect(!string(document).contains("\u{0C}"))
        #expect(string(document).contains("a\u{240C}b"))
        #expect(string(document).contains("a\u{240D}b"))
        #expect(string(document).contains("a\u{2424}b"))
    }

    @Test func keepsACarriageReturnAtTheEndOfALine() throws {
        // With the newline after it, it ends the row, and it's still there
        // when the text is copied.
        let document = try document("@@ -0,0 +1,2 @@\n+a\r\n+b\r\n")
        #expect(string(document) == "@@ -0,0 +1,2 @@\na\r\nb\r\n")
        document.layoutManager.ensureLayout(for: document.container)
        var rows = 0
        let glyphs = document.layoutManager.glyphRange(for: document.container)
        document.layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in rows += 1 }
        #expect(rows == 3)
        #expect(document.lineStarts == [0, 16, 19])
    }

    @Test func readsTextThatIsntUTF8AsLatin1() throws {
        let document = try document(Array("@@ -0,0 +1 @@\n+caf".utf8) + [0xE9, 0x0A])
        #expect(string(document) == "@@ -0,0 +1 @@\ncafé\n")
    }

    @Test func keepsUTF8() throws {
        #expect(string(try document("@@ -0,0 +1 @@\n+Kovač 日本語 🙂\n")) == "@@ -0,0 +1 @@\nKovač 日本語 🙂\n")
    }

    @Test func cutsOffAVeryLongLine() throws {
        let long = String(repeating: "x", count: DiffTextBuilder.lineLimit + 100)
        let document = try document("@@ -0,0 +1,2 @@\n+\(long)\n+next\n")
        let lines = string(document).split(separator: "\n")
        #expect(lines[1].hasPrefix(String(repeating: "x", count: DiffTextBuilder.lineLimit) + " …"))
        #expect(lines[1].count < DiffTextBuilder.lineLimit + 100)
        #expect(lines[2] == "next")
        #expect(document.lineStarts[2] == (string(document) as NSString).range(of: "next").location)
    }

    @Test func doesntCutOffACharacterInTheMiddle() throws {
        // Each is two bytes, so the limit may fall inside one.
        let long = String(repeating: "é", count: DiffTextBuilder.lineLimit)
        let shown = string(try document("@@ -0,0 +1 @@\n+\(long)x\n"))
        #expect(!shown.contains("\u{FFFD}"))
        #expect(!shown.contains("Ã"))
        #expect(shown.contains("é …"))
    }

    @Test func countsColumnsWithTabs() throws {
        // Longer than the hunk's header.
        #expect(try document("@@ -0,0 +1 @@\n+\t\tabc\n").columns == 19)
        #expect(try document("@@ -0,0 +1 @@\n+abcdefghijkl\tc\n").columns == 17)
    }

    @Test func allowsForWideCharactersWhenCountingColumns() throws {
        #expect(try document("@@ -0,0 +1 @@\n+日本語日本語日本語\n").columns >= 18)
    }

    @Test func countsTheDigitsOfTheLargestLineNumber() throws {
        #expect(try document("@@ -0,0 +1 @@\n+a\n").numberDigits <= 2)
        #expect(try document("@@ -1200,0 +12345 @@\n+a\n").numberDigits == 5)
    }

    @Test func laysOutAheadOfTime() throws {
        // A text view asked for the height then has no estimate to make.
        let document = try document("@@ -0,0 +1,3 @@\n+a\n+b\n+c\n")
        #expect(document.layoutManager.firstUnlaidCharacterIndex() >= document.storage.length)
    }

    @Test func leavesAVeryLongPatchToLayOutAsItsLookedAt() throws {
        let count = DiffTextBuilder.wholeLayoutLimit + 1
        let lines = String(repeating: "+a\n", count: count)
        let document = try document("@@ -0,0 +1,\(count) @@\n" + lines)
        #expect(document.layoutManager.firstUnlaidCharacterIndex() < document.storage.length)
    }
}
