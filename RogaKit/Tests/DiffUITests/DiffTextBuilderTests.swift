import AppKit
import GitCore
import Testing
import ThemeUI
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
        // The header is in the band's two rows, which the layout manager draws.
        #expect(string(document) == "\n\nsame\nold\nnew\n")
        #expect(document.hunkBands == [HunkBand(row: 0, line: 0, label: "@@ -1,2 +1,2 @@ func main()")])
    }

    /// Two rows, empty in the text, that still say they're the header's, so that
    /// nothing takes them for lines of the file. The commands for a hunk name it
    /// by its header's place in the patch, which is behind a band of rows each.
    @Test func eachHunkHasABandOfTwoRows() throws {
        let hunk = { (start: Int) in "@@ -\(start),2 +\(start),2 @@ func f\(start)()\n line \(start)\n-old\n+new\n" }
        let patch = try PatchParser.parse(Array((hunk(10) + hunk(40)).utf8))
        let document = DiffTextBuilder.build(patch)
        #expect(document.lines.count == patch.lines.count + 2)
        #expect(document.hunkHeaders == [0, 5])
        #expect(document.hunkBands.map(\.line) == [0, 4])
        #expect(document.hunkBands.map(\.label) == ["@@ -10,2 +10,2 @@ func f10()", "@@ -40,2 +40,2 @@ func f40()"])
        #expect(document.lines[5].kind == .hunkHeader && document.lines[6].kind == .hunkHeader)
        #expect(document.lines[5].newNumber == nil && document.lines[6].oldNumber == nil)
        #expect(document.hunkBand(atRow: 9)?.line == 4)
        #expect(document.hunkBand(atRow: 4)?.line == 0)
        #expect(document.hunkBand(atRow: 10) == nil)
        // A band has no fill: the line at its bottom sets it apart.
        #expect(document.background(ofRow: 5) == nil)
    }

    /// The gap above a band's line gives way in the smallest fonts, so that a
    /// button of the usual size still fits under it.
    @Test func aBandFitsAButtonInEveryFont() {
        #expect(HunkBand.gap(lineHeight: 17) == 8)
        #expect(HunkBand.buttonHeight(lineHeight: 17) == 22)
        for size in CodeFont.sizes {
            let lineHeight = DiffMetrics.of(CodeFont(size: size)).lineHeight
            let content = HunkBand.content(lineHeight: lineHeight)
            #expect(content.top >= 0)
            #expect(content.top + content.height == lineHeight * 2)
            #expect(HunkBand.buttonHeight(lineHeight: lineHeight) <= content.height - 2)
            #expect(HunkBand.buttonHeight(lineHeight: lineHeight) >= 20)
        }
    }

    // MARK: The whole file (decision 74)

    /// A whole file as git prints it: one hunk from the first line, with the
    /// tenth of its twelve lines changed.
    static let wholeFile = "@@ -1,12 +1,12 @@\n" + (1...9).map { " line \($0)\n" }.joined() + "-line ten\n+line TEN\n line 11\n line 12\n"
    /// The same change as git prints it in hunks.
    static let hunks = "@@ -7,6 +7,6 @@\n line 7\n line 8\n line 9\n-line ten\n+line TEN\n line 11\n line 12\n"

    @Test func aWholeFileHasNoHunkHeaders() throws {
        let document = DiffTextBuilder.build(try PatchParser.parse(Array(Self.wholeFile.utf8)), layout: .inline)
        #expect(document.layout == .inline)
        #expect(string(document) == (1...9).map { "line \($0)\n" }.joined() + "line ten\nline TEN\nline 11\nline 12\n")
        #expect(document.lines.count == 13)
        #expect(document.hunkHeaders.isEmpty)
        #expect(document.hunkHeader(atRow: 5) == nil)
        // Each row still has its line's numbers, and the first one is line 1.
        #expect(document.lines[0].newNumber == 1)
        #expect(document.lines[9].kind == .removed)
        #expect(document.firstChangedRow == 9)
        // The words that changed are still marked.
        #expect(document.changedWords.count == 2)
    }

    @Test func hunksKeepTheirHeaders() throws {
        let document = try document(Self.hunks)
        #expect(document.layout == .hunks)
        #expect(document.hunkHeaders == [0])
        #expect(document.firstChangedRow == 5)
    }

    /// A file that became another kind of file is the old file and then the new one.
    @Test func aWholeFileOfTwoKindsHasBothWithoutHeaders() throws {
        let patch = try PatchParser.parse(Array("@@ -1 +0,0 @@\n-link target\n@@ -0,0 +1 @@\n+run.sh\n\\ No newline at end of file\n".utf8))
        #expect(string(DiffTextBuilder.build(patch, layout: .inline)) == "link target\nrun.sh\nNo newline at end of file\n")
    }

    @Test func findsALineInTheOtherLayout() throws {
        let hunks = try document(Self.hunks)
        let whole = DiffTextBuilder.build(try PatchParser.parse(Array(Self.wholeFile.utf8)), layout: .inline)

        // Line 8 is the second row under the hunk's band, and the eighth of the file.
        #expect(hunks.lines[3].newNumber == 8)
        #expect(whole.row(showing: hunks.lines[3]) == (7, true))
        #expect(hunks.row(showing: whole.lines[7]) == (3, true))
        // A removed line and the added one after it are different rows.
        #expect(whole.row(showing: hunks.lines[5]) == (9, true))
        #expect(whole.row(showing: hunks.lines[6]) == (10, true))
        #expect(hunks.row(showing: whole.lines[9]) == (5, true))
        // Line 2 isn't in the hunks, so it gives the band of the hunk after it.
        #expect(hunks.row(showing: whole.lines[1]) == (0, false))
    }

    @Test func aLineBetweenHunksGivesTheNextHunkAndOnePastThemTheLast() throws {
        let hunk = { (start: Int) in "@@ -\(start),2 +\(start),2 @@\n line \(start)\n-old\n+new\n" }
        let hunks = try document(hunk(10) + hunk(40))
        #expect(hunks.hunkHeaders == [0, 5])
        func line(_ number: Int) -> FilePatch.Line {
            FilePatch.Line(kind: .context, oldNumber: number, newNumber: number, text: 0..<0)
        }
        #expect(hunks.row(showing: line(5)) == (0, false))
        #expect(hunks.row(showing: line(25)) == (5, false))
        #expect(hunks.row(showing: line(90)) == (5, false))
    }

    @Test func findsTheFirstLineOfTheFileAtOrAfterARow() throws {
        let hunks = try document(Self.hunks)
        // The band's rows aren't lines of the file, and the row under them is.
        #expect(hunks.fileRow(atOrAfter: 0) == 2)
        #expect(hunks.fileRow(atOrAfter: 1) == 2)
        #expect(hunks.fileRow(atOrAfter: -3) == 2)
        #expect(hunks.fileRow(atOrAfter: 3) == 3)
        // Past the end, it's the last one.
        #expect(hunks.fileRow(atOrAfter: 99) == 8)
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
        #expect(document.lineIndex(atCharacter: 0) == 0)
        #expect(document.lineIndex(atCharacter: 1) == 1)
        // After the band's two empty rows.
        for (index, line) in ["aa", "é𝄞", "c"].enumerated().map({ ($0 + 2, $1) }) {
            let start = text.range(of: line).location
            try #require(start != NSNotFound)
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
        #expect(rows == lines.count + HunkBand.rowCount)
        #expect(!string(document).contains("\u{0C}"))
        #expect(string(document).contains("a\u{240C}b"))
        #expect(string(document).contains("a\u{240D}b"))
        #expect(string(document).contains("a\u{2424}b"))
    }

    @Test func keepsACarriageReturnAtTheEndOfALine() throws {
        // With the newline after it, it ends the row, and it's still there
        // when the text is copied.
        let document = try document("@@ -0,0 +1,2 @@\n+a\r\n+b\r\n")
        #expect(string(document) == "\n\na\r\nb\r\n")
        document.layoutManager.ensureLayout(for: document.container)
        var rows = 0
        let glyphs = document.layoutManager.glyphRange(for: document.container)
        document.layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in rows += 1 }
        #expect(rows == 4)
        #expect(document.lineStarts == [0, 1, 2, 5])
    }

    @Test func readsTextThatIsntUTF8AsLatin1() throws {
        let document = try document(Array("@@ -0,0 +1 @@\n+caf".utf8) + [0xE9, 0x0A])
        #expect(string(document) == "\n\ncafé\n")
    }

    @Test func keepsUTF8() throws {
        #expect(string(try document("@@ -0,0 +1 @@\n+Kovač 日本語 🙂\n")) == "\n\nKovač 日本語 🙂\n")
    }

    @Test func cutsOffAVeryLongLine() throws {
        let long = String(repeating: "x", count: DiffTextBuilder.lineLimit + 100)
        let document = try document("@@ -0,0 +1,2 @@\n+\(long)\n+next\n")
        // Under the band's two empty rows.
        let lines = string(document).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[2].hasPrefix(String(repeating: "x", count: DiffTextBuilder.lineLimit) + " …"))
        #expect(lines[2].count < DiffTextBuilder.lineLimit + 100)
        #expect(lines[3] == "next")
        #expect(document.lineStarts[3] == (string(document) as NSString).range(of: "next").location)
    }

    @Test func doesntCutOffACharacterInTheMiddle() throws {
        // Each is two bytes, so the limit may fall inside one.
        let long = String(repeating: "é", count: DiffTextBuilder.lineLimit)
        let shown = string(try document("@@ -0,0 +1 @@\n+\(long)x\n"))
        #expect(!shown.contains("\u{FFFD}"))
        #expect(!shown.contains("Ã"))
        #expect(shown.contains("é …"))
    }

    @Test func aLongHeaderCountsTowardTheColumns() throws {
        // The band draws it, and the text scrolls as far as it goes.
        #expect(try document("@@ -0,0 +1 @@ func aFunctionWithAVeryLongName()\n+a\n").columns == 47)
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
