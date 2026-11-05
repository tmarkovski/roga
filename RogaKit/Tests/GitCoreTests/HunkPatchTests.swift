import Foundation
import Testing
@testable import GitCore

/// A hunk cut out of a file's patch, as a patch of its own.
@Suite(.timeLimit(.minutes(1)))
struct HunkPatchTests {
    static let header = """
    diff --git a/a.txt b/a.txt
    old mode 100644
    new mode 100755
    index 1c99002..1b9797b
    --- a/a.txt
    +++ b/a.txt

    """

    func patch(_ text: String) throws -> FilePatch {
        try PatchParser.parse(Array(text.utf8))
    }

    func headers(_ patch: FilePatch) -> [Int] {
        patch.lines.indices.filter { patch.lines[$0].kind == .hunkHeader }
    }

    func text(_ hunk: HunkPatch?) -> String? {
        hunk.map { String(decoding: $0.bytes, as: UTF8.self) }
    }

    @Test func keepsOnlyTheLinesThatSayWhichFileItIs() throws {
        let patch = try patch(Self.header + """
        @@ -1,2 +1,2 @@
         one
        -two
        +2

        """)
        #expect(text(patch.hunk(at: 0)) == """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
         one
        -two
        +2

        """)
    }

    @Test func aHunkPutsItsCurrentLineOnBothSides() throws {
        let patch = try patch(Self.header + """
        @@ -1,3 +1,6 @@
         one
        +a
        +b
        +c
         two
         three
        @@ -27,2 +30,2 @@ func thing() {
        -old
        +new
         same

        """)
        let hunks = headers(patch)
        #expect(hunks.count == 2)
        #expect(patch.hunkCount == 2)
        #expect(text(patch.hunk(at: hunks[1])) == """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -30,2 +30,2 @@
        -old
        +new
         same

        """)
    }

    @Test func aCountOfZeroSaysWhatComesBeforeIt() throws {
        // Adding to an empty file, and emptying one.
        let added = try patch(Self.header + "@@ -0,0 +1,2 @@\n+a\n+b\n")
        #expect(text(added.hunk(at: 0))?.contains("@@ -0,0 +1,2 @@\n") == true)
        let removed = try patch(Self.header + "@@ -1,2 +0,0 @@\n-a\n-b\n")
        #expect(text(removed.hunk(at: 0))?.contains("@@ -1,2 +0,0 @@\n") == true)
        // Lines added with no context, after the fifth.
        let inserted = try patch(Self.header + "@@ -5,0 +8,1 @@\n+a\n")
        #expect(text(inserted.hunk(at: 0))?.contains("@@ -7,0 +8,1 @@\n") == true)
    }

    @Test func keepsTheRemarkAboutANewlineAtTheEnd() throws {
        let patch = try patch(Self.header + """
        @@ -1 +1,2 @@
        -one
        \\ No newline at end of file
        +one
        +two
        \\ No newline at end of file

        """)
        #expect(text(patch.hunk(at: 0))?.hasSuffix("""
        -one
        \\ No newline at end of file
        +one
        +two
        \\ No newline at end of file

        """) == true)
    }

    @Test func aLineThatLooksLikeAHeaderStaysInItsHunk() throws {
        let patch = try patch(Self.header + """
        @@ -1,2 +1,2 @@
        --- a/a.txt
        +@@ -1 +1 @@
         same
        @@ -9 +9 @@
        -x
        +y

        """)
        #expect(patch.hunkCount == 2)
        #expect(text(patch.hunk(at: 0))?.contains("-- a/a.txt\n+@@ -1 +1 @@\n same\n") == true)
        #expect(text(patch.hunk(at: 0))?.contains("-x") == false)
    }

    @Test func onlyAHeaderIsAHunk() throws {
        let patch = try patch(Self.header + "@@ -1 +1 @@\n-a\n+b\n")
        #expect(patch.hunk(at: 1) == nil)
        #expect(patch.hunk(at: 99) == nil)
        #expect(patch.hunk(at: -1) == nil)
    }

    @Test func aFileThatsNewOrGoneHasNoHunkOfItsOwn() throws {
        let new = try patch("diff --git a/n b/n\nnew file mode 100644\n--- /dev/null\n+++ b/n\n@@ -0,0 +1 @@\n+a\n")
        #expect(new.hunk(at: 0) == nil)
        let gone = try patch("diff --git a/n b/n\ndeleted file mode 100644\n--- a/n\n+++ /dev/null\n@@ -1 +0,0 @@\n-a\n")
        #expect(gone.hunk(at: 0) == nil)
    }

    @Test func aFileThatBecameAnotherKindHasNoHunkOfItsOwn() throws {
        let patch = try patch("""
        diff --git a/t b/t
        deleted file mode 100644
        --- a/t
        +++ /dev/null
        @@ -1 +0,0 @@
        -a
        diff --git a/t b/t
        new file mode 120000
        --- /dev/null
        +++ b/t
        @@ -0,0 +1 @@
        +target

        """)
        #expect(headers(patch).allSatisfy { patch.hunk(at: $0) == nil })
    }
}
