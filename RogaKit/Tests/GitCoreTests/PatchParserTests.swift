import Testing
@testable import GitCore

struct PatchParserTests {
    func parse(_ text: String) throws(ParseError) -> FilePatch {
        try PatchParser.parse(Array(text.utf8))
    }

    func texts(_ patch: FilePatch) -> [String] {
        patch.lines.map { String(decoding: patch.text(of: $0), as: UTF8.self) }
    }

    let header = """
        diff --git a/a.txt b/a.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/a.txt

        """

    @Test func numbersTheLinesOfAHunk() throws {
        let patch = try parse(header + """
            @@ -10,4 +20,4 @@ func main()
             same
            -old
            -older
            +new
            +newer
             same again

            """)
        #expect(patch.lines == [
            .init(kind: .hunkHeader, text: patch.lines[0].text),
            .init(kind: .context, oldNumber: 10, newNumber: 20, text: patch.lines[1].text),
            .init(kind: .removed, oldNumber: 11, text: patch.lines[2].text),
            .init(kind: .removed, oldNumber: 12, text: patch.lines[3].text),
            .init(kind: .added, newNumber: 21, text: patch.lines[4].text),
            .init(kind: .added, newNumber: 22, text: patch.lines[5].text),
            .init(kind: .context, oldNumber: 13, newNumber: 23, text: patch.lines[6].text),
        ])
        #expect(texts(patch) == ["@@ -10,4 +20,4 @@ func main()", "same", "old", "older", "new", "newer", "same again"])
    }

    @Test func restartsTheNumbersForEachHunk() throws {
        let patch = try parse(header + """
            @@ -1 +1 @@
            -a
            +b
            @@ -100,0 +101 @@ section
            +c

            """)
        #expect(patch.lines.map(\.newNumber) == [nil, nil, 1, nil, 101])
        #expect(patch.lines.map(\.oldNumber) == [nil, 1, nil, nil, nil])
    }

    @Test func readsACountOfOneThatsLeftOut() throws {
        let patch = try parse(header + "@@ -5 +7 @@\n-a\n+b\n")
        #expect(patch.lines[1].oldNumber == 5)
        #expect(patch.lines[2].newNumber == 7)
    }

    @Test func readsARemarkAboutAMissingNewline() throws {
        // It comes in the middle of a hunk, and after the last line of one.
        let patch = try parse(header + """
            @@ -1 +1,2 @@
            -a
            \\ No newline at end of file
            +b
            +c
            \\ No newline at end of file

            """)
        #expect(patch.lines.map(\.kind) == [.hunkHeader, .removed, .noNewline, .added, .added, .noNewline])
        #expect(texts(patch)[2] == "No newline at end of file")
        #expect(patch.lines[4].newNumber == 2)
    }

    @Test func readsTextThatLooksLikeOtherParts() throws {
        let patch = try parse(header + """
            @@ -1,2 +1,3 @@
            -@@ -1 +1 @@
             diff --git a/a b/a
            +--- a/a.txt
            ++++ b/a.txt

            """)
        #expect(texts(patch).dropFirst() == ["@@ -1 +1 @@", "diff --git a/a b/a", "--- a/a.txt", "+++ b/a.txt"])
        #expect(patch.lines.map(\.kind) == [.hunkHeader, .removed, .context, .added, .added])
    }

    @Test func readsABlankLineOfContextWithoutItsSpace() throws {
        // What diff.suppressBlankEmpty prints.
        let patch = try parse(header + "@@ -1,2 +1,2 @@\n\n-a\n+b\n")
        #expect(patch.lines[1].kind == .context)
        #expect(patch.lines[1].oldNumber == 1)
        #expect(patch.lines[1].text.isEmpty)
    }

    @Test func readsEverySectionOfAFile() throws {
        // What git prints for a file that became a symbolic link.
        let patch = try parse("""
            diff --git a/link b/link
            deleted file mode 100644
            index 1111111..0000000
            --- a/link
            +++ /dev/null
            @@ -1 +0,0 @@
            -text
            diff --git a/link b/link
            new file mode 120000
            index 0000000..2222222
            --- /dev/null
            +++ b/link
            @@ -0,0 +1 @@
            +target
            \\ No newline at end of file

            """)
        #expect(texts(patch) == ["@@ -1 +0,0 @@", "text", "@@ -0,0 +1 @@", "target", "No newline at end of file"])
    }

    @Test func keepsBytesThatArentUTF8() throws {
        let patch = try PatchParser.parse(Array("@@ -1 +1 @@\n-".utf8) + [0xE9] + Array("\n+\r\n".utf8))
        #expect(Array(patch.text(of: patch.lines[1])) == [0xE9])
        #expect(Array(patch.text(of: patch.lines[2])) == [0x0D])
    }

    @Test func findsNoLinesWithoutHunks() throws {
        #expect(try parse("").lines.isEmpty)
        #expect(try parse("diff --git a/a b/a\nold mode 100644\nnew mode 100755\n").lines.isEmpty)
        #expect(try parse("diff --git a/a b/a\nindex 1..2 100644\nBinary files a/a and b/a differ\n").lines.isEmpty)
    }

    @Test func readsALastLineWithoutANewline() throws {
        #expect(texts(try parse("@@ -1 +1 @@\n-a\n+b")) == ["@@ -1 +1 @@", "a", "b"])
    }

    @Test(arguments: [
        "@@ nonsense @@\n",
        "@@ -a +1 @@\n",
        "@@ -1,x +1 @@\n",
        "@@ -1 +1\n",
        "@@ -99999999999999999999 +1 @@\n",
        // Stops before the hunk's header said it would.
        "@@ -1,2 +1,2 @@\n a\n",
        // A line that isn't part of a hunk.
        "@@ -1 +1 @@\n?\n",
        // More lines of one side than the header said.
        "@@ -1,2 +1 @@\n+a\n+b\n",
        "@@ -1 +1,2 @@\n-a\n-b\n",
        "@@ -1,2 +1 @@\n a\n b\n",
    ])
    func refusesWhatGitWouldntPrint(_ text: String) {
        #expect(throws: ParseError.self) { try parse(text) }
    }
}

struct BinaryPatchTests {
    @Test func saysWhenGitCalledAFileBinary() throws {
        let patch = try PatchParser.parse(Array("""
        diff --git a/picture.png b/picture.png
        index 0000000..87ae6b6
        Binary files /dev/null and b/picture.png differ

        """.utf8))
        #expect(patch.isBinary)
        #expect(patch.lines.isEmpty)
    }

    @Test func aLineInAHunkDoesntMakeAFileBinary() throws {
        let patch = try PatchParser.parse(Array("""
        @@ -1 +1 @@
        -Binary files differ
        +Binary files /dev/null and b/picture.png differ

        """.utf8))
        #expect(!patch.isBinary)
        #expect(patch.lines.count == 3)
    }
}
