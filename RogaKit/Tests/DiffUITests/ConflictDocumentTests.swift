import AppKit
import GitCore
import Testing
@testable import DiffUI

/// How a file with conflicts shows (decision 60).
struct ConflictDocumentTests {
    let sides = ConflictSides(
        ours: .init(name: "main", detail: "a17f9d3 · Add a retry button", keepTitle: "Keep main's", keptTitle: "Kept main's"),
        theirs: .init(name: "origin/main", detail: "86b3386 · Show the error", keepTitle: "Keep origin/main's", keptTitle: "Kept origin/main's")
    )

    let file = ConflictedFile.parse(Array("""
        top
        <<<<<<< HEAD
        ours
        =======
        theirs
        >>>>>>> origin/main
        middle
        <<<<<<< HEAD
        =======
        added
        >>>>>>> origin/main
        end

        """.utf8))

    func rows(_ document: DiffDocument) -> [String] {
        document.storage.string.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func numbers(_ document: DiffDocument) -> [Int?] {
        document.lines.map(\.newNumber)
    }

    @Test func showsEachConflictWithItsSidesNamed() {
        let document = DiffTextBuilder.build(file, choices: [:], sides: sides)
        #expect(rows(document) == [
            "top",
            "",
            "",
            "main · a17f9d3 · Add a retry button",
            "ours",
            "origin/main · 86b3386 · Show the error",
            "theirs",
            "middle",
            "",
            "",
            "main · a17f9d3 · Add a retry button",
            "No lines",
            "origin/main · 86b3386 · Show the error",
            "added",
            "end",
        ])
        // The numbers are the lines on disk, where the markers take lines too.
        #expect(numbers(document) == [1, nil, nil, nil, 3, nil, 5, 7, nil, nil, nil, nil, nil, 10, 12])
        #expect(document.conflictBands == [
            ConflictBand(row: 1, conflict: 0, isResolved: false),
            ConflictBand(row: 8, conflict: 1, isResolved: false),
        ])
        #expect(document.unresolvedConflictRows == [1..<7, 8..<14])
        #expect(document.conflicts?.edits == [0: "ours\ntheirs", 1: "added"])
        #expect(document.hasConflicts)
        #expect(document.hunkHeaders.isEmpty)
    }

    @Test func showsWhatAResolvedConflictKept() {
        let document = DiffTextBuilder.build(file, choices: [0: .both, 1: .ours], sides: sides)
        #expect(rows(document) == [
            "top",
            "",
            "",
            "ours",
            "theirs",
            "middle",
            "",
            "",
            "No lines",
            "end",
        ])
        #expect(numbers(document) == [1, nil, nil, 2, 3, 4, nil, nil, nil, 5])
        #expect(document.conflictBands.map(\.isResolved) == [true, true])
        #expect(document.conflictBands.map(\.kept) == ["Kept both", "Kept main's"])
        #expect(document.unresolvedConflictRows.isEmpty)
        #expect(document.conflicts?.edits.isEmpty == true)
    }

    @Test func colorsEachSide() {
        let document = DiffTextBuilder.build(file, choices: [:], sides: sides)
        #expect(document.background(ofRow: 0) == nil)
        #expect(document.background(ofRow: 4) != nil)
        #expect(document.background(ofRow: 6) != nil)
        #expect(document.conflicts?.rows[4] == .line(.ours))
        #expect(document.conflicts?.rows[6] == .line(.theirs))
        #expect(ConflictRow.line(.ours).bar == ConflictColors.ours)
        #expect(ConflictRow.line(.theirs).bar == ConflictColors.theirs)
    }

    @Test func showsWhatBothStartedFromWhenTheFileHasIt() {
        let file = ConflictedFile.parse(Array("<<<<<<< HEAD\nours\n||||||| 18f3a41\nbase\n=======\ntheirs\n>>>>>>> x\n".utf8))
        let document = DiffTextBuilder.build(file, choices: [:], sides: sides)
        #expect(rows(document).contains("What both started from, 18f3a41"))
        #expect(rows(document).contains("base"))
    }
}
