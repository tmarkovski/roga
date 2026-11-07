import Testing
@testable import GitCore

/// Finding the conflicts in a file and writing what resolves them (decision 60).
struct ConflictedFileTests {
    func parse(_ text: String) -> ConflictedFile {
        ConflictedFile.parse(Array(text.utf8))
    }

    func text(_ bytes: some Collection<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    let merge = """
        a
        <<<<<<< HEAD
        ours
        =======
        theirs one
        theirs two
        >>>>>>> origin/main
        b

        """

    @Test func findsAConflictsSidesAndLabels() {
        let file = parse(merge)
        #expect(file.conflicts.count == 1)
        let conflict = file.conflicts[0]
        #expect(text(file.bytes[conflict.ours]) == "ours\n")
        #expect(text(file.bytes[conflict.theirs]) == "theirs one\ntheirs two\n")
        #expect(conflict.base == nil)
        #expect(conflict.oursLabel == "HEAD")
        #expect(conflict.theirsLabel == "origin/main")
        #expect(conflict.line == 2)
        #expect(text(file.bytes[conflict.range]).hasPrefix("<<<<<<< HEAD\n"))
        #expect(text(file.bytes[conflict.range]).hasSuffix(">>>>>>> origin/main\n"))
    }

    @Test func findsWhatBothStartedFromInDiff3Style() {
        let file = parse("<<<<<<< HEAD\nours\n||||||| 18f3a41\nbase\n=======\ntheirs\n>>>>>>> a17f9d3 (Add a retry button)\n")
        let conflict = file.conflicts[0]
        #expect(text(file.bytes[conflict.ours]) == "ours\n")
        #expect(conflict.base.map { text(file.bytes[$0]) } == "base\n")
        #expect(conflict.baseLabel == "18f3a41")
        #expect(text(file.bytes[conflict.theirs]) == "theirs\n")
        #expect(conflict.theirsLabel == "a17f9d3 (Add a retry button)")
    }

    @Test func aSideCanBeEmpty() {
        let file = parse("<<<<<<< HEAD\nkept\n=======\n>>>>>>> parent of 86b3386 (Show the error)\n")
        let conflict = file.conflicts[0]
        #expect(text(file.bytes[conflict.ours]) == "kept\n")
        #expect(conflict.theirs.isEmpty)
        #expect(conflict.theirsLabel == "parent of 86b3386 (Show the error)")
    }

    @Test func findsSeveralConflicts() {
        let file = parse(merge + merge)
        #expect(file.conflicts.count == 2)
        #expect(file.conflicts[1].line == 10)
    }

    @Test func keepsCarriageReturnsOutOfLabels() {
        let file = parse("<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> feature\r\n")
        let conflict = file.conflicts[0]
        #expect(conflict.oursLabel == "HEAD")
        #expect(conflict.theirsLabel == "feature")
        #expect(text(file.bytes[conflict.ours]) == "ours\r\n")
    }

    @Test func readsAConflictAtTheEndWithoutANewline() {
        let file = parse("<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature")
        #expect(file.conflicts.count == 1)
        #expect(file.conflicts[0].range == 0..<file.bytes.count)
    }

    @Test func takesMarkersOfAnotherSize() {
        let file = parse("<<<<<<<< HEAD\nours\n=======\nstill ours? no, theirs\n========\ntheirs\n>>>>>>>> feature\n")
        #expect(file.conflicts.count == 1)
        #expect(text(file.bytes[file.conflicts[0].ours]) == "ours\n=======\nstill ours? no, theirs\n")
        #expect(text(file.bytes[file.conflicts[0].theirs]) == "theirs\n")
    }

    @Test func leavesStrayMarkersAsText() {
        #expect(parse("Title\n=======\n\n>>>>>>> quoted\n").conflicts.isEmpty)
        #expect(parse("<<<<<<< HEAD\nnever closed\n=======\n").conflicts.isEmpty)
        #expect(parse("<<<<<<<HEAD\nours\n=======\ntheirs\n>>>>>>> x\n").conflicts.isEmpty)
    }

    @Test func startsAgainAtAMarkerInsideAConflict() {
        let file = parse("<<<<<<< HEAD\nstray\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> x\n")
        #expect(file.conflicts.count == 1)
        #expect(file.conflicts[0].line == 3)
    }

    @Test func resolvesEachConflictItsOwnWay() {
        let file = parse(merge + merge + merge)
        let resolved = file.resolving([0: .ours, 1: .both, 2: .lines(ConflictedFile.lines(typed: "mine"))])
        #expect(text(resolved) == "a\nours\nb\na\nours\ntheirs one\ntheirs two\nb\na\nmine\nb\n")
        #expect(text(file.resolving([1: .theirs])) == merge + "a\ntheirs one\ntheirs two\nb\n" + merge)
        #expect(file.resolving([:]) == file.bytes)
    }

    @Test func linesTypedEndWithANewline() {
        #expect(ConflictedFile.lines(typed: "one\ntwo") == Array("one\ntwo\n".utf8))
        #expect(ConflictedFile.lines(typed: "one\n") == Array("one\n".utf8))
        #expect(ConflictedFile.lines(typed: "").isEmpty)
    }
}
