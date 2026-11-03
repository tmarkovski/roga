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

    @Test func findsTextIgnoringCase() throws {
        let document = DiffTextBuilder.build(try PatchParser.parse(Array("@@ -1 +1 @@\n-Old line\n+new LINE\n".utf8)))
        let text = document.storage.string as NSString
        #expect(document.ranges(of: "line").map(text.substring) == ["line", "LINE"])
        #expect(document.ranges(of: "nothing").isEmpty)
        #expect(document.ranges(of: "").isEmpty)
    }

    @Test func matchesDontOverlap() throws {
        let document = DiffTextBuilder.build(try PatchParser.parse(Array("@@ -0,0 +1 @@\n+aaaaa\n".utf8)))
        #expect(document.ranges(of: "aa").count == 2)
    }

    @Test func findsTextAfterCharactersThatTakeTwoCodeUnits() throws {
        let document = DiffTextBuilder.build(try PatchParser.parse(Array("@@ -0,0 +1 @@\n+😀 word\n".utf8)))
        let text = document.storage.string as NSString
        #expect(document.ranges(of: "word").map(text.substring) == ["word"])
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

struct ChangedWordsTests {
    func document(_ lines: [String]) throws -> DiffDocument {
        let oldCount = lines.count { $0.hasPrefix("-") || $0.hasPrefix(" ") }
        let newCount = lines.count { $0.hasPrefix("+") || $0.hasPrefix(" ") }
        let patch = "@@ -1,\(oldCount) +1,\(newCount) @@\n" + lines.map { $0 + "\n" }.joined()
        return DiffTextBuilder.build(try PatchParser.parse(Array(patch.utf8)))
    }

    /// What differs on each changed line of a patch, as text.
    func changedWords(_ lines: String...) throws -> [String] {
        let document = try document(lines)
        return document.changedWords.map((document.storage.string as NSString).substring)
    }

    @Test func marksOnlyTheWordThatChanged() throws {
        #expect(try changedWords("-let name = 1", "+let name = 2") == ["1", "2"])
    }

    @Test func marksWhatWasAddedInTheMiddleOfALine() throws {
        #expect(try changedWords("-open(path)", "+open(path, line)") == [", line"])
    }

    @Test func comparesWholeWords() throws {
        #expect(try changedWords("-the file is open", "+the files is open") == ["file", "files"])
    }

    @Test func joinsWordsWithOnlySpacesBetweenThem() throws {
        #expect(try changedWords("-keep one two three keep keep", "+keep four five six keep keep") == ["one two three", "four five six"])
    }

    @Test func doesntJoinWordsWithOtherTextBetweenThem() throws {
        #expect(try changedWords("-one keep two keep keep", "+three keep four keep keep") == ["one", "two", "three", "four"])
    }

    @Test func marksAChangeInIndentation() throws {
        #expect(try changedWords("-  call()", "+      call()") == ["    "])
        #expect(try changedWords("-call()", "+  call()") == ["  "])
        #expect(try changedWords("-\tcall()", "+    call()") == ["\t", "    "])
    }

    @Test func marksAChangeInTheSpacesInALine() throws {
        #expect(try changedWords("-a,b", "+a, b") == [" "])
        #expect(try changedWords("-a  = 1", "+a = 1") == [" "])
    }

    @Test func marksSpacesAtTheEndOfALine() throws {
        #expect(try changedWords("-let a = 1  ", "+let a = 1") == ["  "])
    }

    @Test func leavesSpacesAloneBetweenWordsThatMoved() throws {
        #expect(try changedWords("-one two", "-three", "+one", "+two three").isEmpty)
    }

    @Test func leavesAWordAloneWhenItMovesToAnotherLine() throws {
        #expect(try changedWords("-first second", "-third fourth fifth", "+first second third", "+fourth fifth").isEmpty)
    }

    @Test func leavesALineAloneWhenNothingOnTheOtherSideIsLikeIt() throws {
        #expect(try changedWords("-let open: () -> Void", "+/// What the rail has selected.").isEmpty)
    }

    @Test func leavesAnAddedLineAloneWhenTheRestOfTheRunIsAComparison() throws {
        #expect(try changedWords("-let name = 1", "+let name = 2", "+@Binding var selection: Item?") == ["1", "2"])
    }

    @Test func leavesLinesAloneWhenOnlyOneSideHasAny() throws {
        #expect(try changedWords("+added", "+another").isEmpty)
        #expect(try changedWords("-removed", "-another").isEmpty)
    }

    @Test func comparesEachRunByItself() throws {
        #expect(try changedWords("-let a = 1", "+let a = 2", " same", "-let b = 3", "+let b = 4") == ["1", "2", "3", "4"])
    }

    @Test func comparesPastARemarkThatALineHasNoNewline() throws {
        #expect(try changedWords("-let a = 1", "\\ No newline at end of file", "+let a = 2") == ["1", "2"])
    }

    @Test func doesntMarkACarriageReturn() throws {
        #expect(try changedWords("-let a = 1\r", "+let a = 1").isEmpty)
    }

    @Test func countsPositionsInCodeUnits() throws {
        #expect(try changedWords("-😀 é keep 1", "+😀 é keep 2") == ["1", "2"])
    }

    @Test func keepsACharacterThatTakesTwoCodeUnitsWhole() throws {
        #expect(try changedWords("-keep keep 😀", "+keep keep 😁") == ["😀", "😁"])
    }

    @Test func givesTheRangesInOrder() throws {
        let document = try document(["-one keep two keep", "+three keep four keep", " same", "-five keep", "+six keep"])
        let starts = document.changedWords.map(\.location)
        #expect(starts.count == 6)
        #expect(starts == starts.sorted())
    }

    @Test func givesUpOnARunWithTooManyDifferences() throws {
        // Half of each line stays the same, and there are enough lines.
        let lineCount = ChangedWords.differenceLimit / 20 + 1
        func lines(_ sign: String) -> [String] {
            (0..<lineCount).map { line in sign + (0..<10).map { "\(sign == "-" ? "old" : "new")\(line)x\($0) keep" }.joined(separator: " ") }
        }
        #expect(try document(lines("-") + lines("+")).changedWords.isEmpty)
    }

    @Test func comparesALongRunWithFewDifferences() throws {
        let same = (0..<ChangedWords.differenceLimit).map { "-keep \($0)" }
        let document = try document(same + ["-keep 1"] + same.map { "+" + $0.dropFirst() } + ["+keep 2"])
        #expect(document.changedWords.count == 2)
    }

    @Test func leavesAVeryLongPatchAlone() throws {
        let lines = (0...DiffTextBuilder.wholeLayoutLimit / 2).flatMap { _ in ["-let a = 1", "+let a = 2"] }
        #expect(try document(lines).changedWords.isEmpty)
    }
}
