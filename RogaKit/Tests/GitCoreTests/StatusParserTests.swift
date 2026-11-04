import Testing
@testable import GitCore

struct StatusParserTests {
    let one = "1111111111111111111111111111111111111111"
    let two = "2222222222222222222222222222222222222222"
    let none = String(repeating: "0", count: 40)

    /// What git prints, with each field on its own line, turned into NUL bytes.
    func output(_ fields: [String]) -> [UInt8] {
        Array(fields.map { $0 + "\0" }.joined().utf8)
    }

    @Test func readsEveryKindOfRecord() throws {
        let changes = try StatusParser.parse(output([
            "# branch.oid \(one)",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +? -?",
            "# stash 2",
            "1 .M N... 100644 100644 100755 \(one) \(one) changed file.txt",
            "1 A. N... 000000 100644 100644 \(none) \(two) new.txt",
            "1 D. N... 100644 000000 000000 \(one) \(none) gone.txt",
            "1 .D N... 100644 100644 000000 \(one) \(one) missing.txt",
            "1 .A N... 000000 000000 100644 \(none) \(none) intent.txt",
            "1 T. N... 100644 120000 120000 \(one) \(two) link",
            "2 R. N... 100644 100644 100644 \(one) \(two) R085 new name.txt", "old name.txt",
            "2 C. N... 100644 100644 100644 \(one) \(two) C100 copy.txt", "source.txt",
            "u UU N... 100644 100644 100644 100644 \(one) \(two) \(one) both sides.txt",
            "? folder/untracked file.txt",
        ]))
        let counted = DiffFile.LineCounts(added: 0, removed: 0)
        let id1 = ObjectID(hex: one)
        let id2 = ObjectID(hex: two)
        #expect(changes.head == id1)
        #expect(changes.fileCount == 10)
        #expect(changes.unstaged == [
            DiffFile(status: .modified, path: "changed file.txt", oldMode: 0o100644, newMode: 0o100755, oldID: id1, lines: counted),
            DiffFile(status: .deleted, path: "missing.txt", oldMode: 0o100644, newMode: 0, oldID: id1, lines: counted),
            DiffFile(status: .added, path: "intent.txt", oldMode: 0, newMode: 0o100644, lines: counted),
        ])
        #expect(changes.staged == [
            DiffFile(status: .added, path: "new.txt", oldMode: 0, newMode: 0o100644, newID: id2, lines: counted),
            DiffFile(status: .deleted, path: "gone.txt", oldMode: 0o100644, newMode: 0, oldID: id1, lines: counted),
            DiffFile(status: .typeChanged, path: "link", oldMode: 0o100644, newMode: 0o120000, oldID: id1, newID: id2, lines: counted),
            DiffFile(status: .renamed(similarity: 85), path: "new name.txt", oldPath: "old name.txt", oldMode: 0o100644, newMode: 0o100644, oldID: id1, newID: id2, lines: counted),
            DiffFile(status: .copied(similarity: 100), path: "copy.txt", oldPath: "source.txt", oldMode: 0o100644, newMode: 0o100644, oldID: id1, newID: id2, lines: counted),
        ])
        #expect(changes.conflicted == [DiffFile(status: .conflicted, path: "both sides.txt", oldMode: 0, newMode: 0, lines: counted)])
        #expect(changes.untracked == [DiffFile(status: .untracked, path: "folder/untracked file.txt", oldMode: 0, newMode: 0, lines: counted)])
    }

    @Test func listsIgnoredFilesWithoutCountingThem() throws {
        let changes = try StatusParser.parse(Array("! .env\0! build folder/\0? new.txt\0".utf8))
        #expect(changes.ignored == [".env", "build folder/"])
        #expect(changes.fileCount == 1)
    }

    @Test func listsAFileWithBothKindsOfChangesTwiceAndCountsItOnce() throws {
        let changes = try StatusParser.parse(output(["1 MM N... 100644 100644 100644 \(one) \(two) both.txt"]))
        #expect(changes.fileCount == 1)
        #expect(changes.staged.map(\.newID) == [ObjectID(hex: two)])
        #expect(changes.unstaged.map(\.oldID) == [ObjectID(hex: two)])
        #expect(changes.unstaged.map(\.newID) == [nil])
    }

    @Test func keepsTheOldPathOnlyOnTheSideThatMoved() throws {
        // Staged as a rename, and then changed in the worktree.
        let changes = try StatusParser.parse(output(["2 RM N... 100644 100644 100644 \(one) \(two) R100 new.txt", "old.txt"]))
        #expect(changes.staged.first?.oldPath == "old.txt")
        #expect(changes.unstaged.first?.oldPath == nil)
        #expect(changes.unstaged.first?.status == .modified)
    }

    @Test func readsARepositoryWithoutCommits() throws {
        let changes = try StatusParser.parse(output(["# branch.oid (initial)", "# branch.head main", "? file.txt"]))
        #expect(changes.head == nil)
        #expect(changes.fileCount == 1)
    }

    @Test func readsAWorktreeWithNoChanges() throws {
        let changes = try StatusParser.parse(output(["# branch.oid \(one)", "# branch.head main"]))
        #expect(changes == WorktreeChanges(head: ObjectID(hex: one)))
        #expect(try StatusParser.parse([]) == WorktreeChanges())
    }

    @Test(arguments: [
        "1 .M N... 100644 100644 100644 nothex nothex a.txt",
        "1 .M N... 100644 a.txt",
        "1 MMM N... 100644 100644 100644 1111111111111111111111111111111111111111 1111111111111111111111111111111111111111 a.txt",
        "u UU N...",
        "?",
        "!",
        "# branch.oid nothex",
    ])
    func refusesARecordItCantRead(_ record: String) {
        #expect(throws: ParseError.self) { try StatusParser.parse(output([record])) }
    }

    @Test func refusesARenameWithoutItsOldPath() {
        #expect(throws: ParseError.self) {
            try StatusParser.parse(output(["2 R. N... 100644 100644 100644 \(one) \(two) R100 new.txt"]))
        }
    }

    @Test func refusesOutputThatStopsInTheMiddleOfAField() {
        #expect(throws: ParseError.self) { try StatusParser.parse(Array("? a.txt".utf8)) }
    }
}

struct NumstatParserTests {
    func output(_ fields: [String]) -> [UInt8] {
        Array(fields.map { $0 + "\0" }.joined().utf8)
    }

    @Test func readsLineCounts() throws {
        let counts = try NumstatParser.parse(output([
            "2\t1\tchanged.txt",
            "-\t-\tpicture.png",
            "3\t0\t", "old.txt", "new.txt",
            "1\t1\twith\ttab.txt",
        ]))
        #expect(counts.count == 4)
        #expect(counts["changed.txt"] == DiffFile.LineCounts(added: 2, removed: 1))
        #expect(counts["picture.png"] == .some(nil))
        #expect(counts["new.txt"] == DiffFile.LineCounts(added: 3, removed: 0))
        #expect(counts["with\ttab.txt"] == DiffFile.LineCounts(added: 1, removed: 1))
    }

    @Test func readsNothing() throws {
        #expect(try NumstatParser.parse([]).isEmpty)
    }

    @Test(arguments: ["no tabs", "a\tb\tfile.txt", "1\t1\t"])
    func refusesARecordItCantRead(_ record: String) {
        #expect(throws: ParseError.self) { try NumstatParser.parse(output([record])) }
    }
}
