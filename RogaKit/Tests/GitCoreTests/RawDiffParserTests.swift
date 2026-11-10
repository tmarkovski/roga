import Testing
@testable import GitCore

struct RawDiffParserTests {
    let one = "1111111111111111111111111111111111111111"
    let two = "2222222222222222222222222222222222222222"
    let none = String(repeating: "0", count: 40)

    /// What git prints, with each field on its own line, turned into NUL bytes.
    func output(_ fields: [String]) -> [UInt8] {
        Array(fields.map { $0 + "\0" }.joined().utf8)
    }

    @Test func readsEveryKindOfChange() throws {
        let files = try RawDiffParser.parse(output([
            ":000000 100644 \(none) \(one) A", "added.txt",
            ":100644 000000 \(one) \(none) D", "deleted.txt",
            ":100644 100755 \(one) \(two) M", "src/changed.txt",
            ":100644 100644 \(one) \(two) R085", "old.txt", "new.txt",
            ":100644 100644 \(one) \(two) C100", "source.txt", "copy.txt",
            ":100644 120000 \(one) \(two) T", "link",
            "2\t0\tadded.txt",
            "0\t3\tdeleted.txt",
            "4\t5\tsrc/changed.txt",
            "1\t1\t", "old.txt", "new.txt",
            "0\t0\t", "source.txt", "copy.txt",
            "1\t1\tlink",
        ]))
        let id1 = ObjectID(hex: one)
        let id2 = ObjectID(hex: two)
        #expect(files == [
            DiffFile(status: .added, path: "added.txt", oldMode: 0, newMode: 0o100644, newID: id1, lines: .init(added: 2, removed: 0)),
            DiffFile(status: .deleted, path: "deleted.txt", oldMode: 0o100644, newMode: 0, oldID: id1, lines: .init(added: 0, removed: 3)),
            DiffFile(status: .modified, path: "src/changed.txt", oldMode: 0o100644, newMode: 0o100755, oldID: id1, newID: id2, lines: .init(added: 4, removed: 5)),
            DiffFile(status: .renamed(similarity: 85), path: "new.txt", oldPath: "old.txt", oldMode: 0o100644, newMode: 0o100644, oldID: id1, newID: id2, lines: .init(added: 1, removed: 1)),
            DiffFile(status: .copied(similarity: 100), path: "copy.txt", oldPath: "source.txt", oldMode: 0o100644, newMode: 0o100644, oldID: id1, newID: id2, lines: .init(added: 0, removed: 0)),
            DiffFile(status: .typeChanged, path: "link", oldMode: 0o100644, newMode: 0o120000, oldID: id1, newID: id2, lines: .init(added: 1, removed: 1)),
        ])
    }

    @Test func countsNoLinesForASubmodule() throws {
        // git counts the `Subproject commit` lines of a submodule's patch.
        let files = try RawDiffParser.parse(output([
            ":160000 160000 \(one) \(two) M", "vendor/parser",
            ":000000 160000 \(none) \(one) A", "vendor/new",
            ":160000 000000 \(one) \(none) D", "vendor/old",
            ":100644 100644 \(one) \(two) M", "file.txt",
            "1\t1\tvendor/parser",
            "1\t0\tvendor/new",
            "0\t1\tvendor/old",
            "1\t1\tfile.txt",
        ]))
        let none = DiffFile.LineCounts(added: 0, removed: 0)
        #expect(files.map(\.lines) == [none, none, none, DiffFile.LineCounts(added: 1, removed: 1)])
        #expect(files.map(\.isSubmodule) == [true, true, true, false])
        #expect(files.map(\.submodule) == [SubmoduleChange(), SubmoduleChange(), SubmoduleChange(), nil])
    }

    @Test func leavesOutTheLinesOfABinaryFile() throws {
        let files = try RawDiffParser.parse(output([
            ":100644 100644 \(one) \(two) M", "image.bin",
            "-\t-\timage.bin",
        ]))
        #expect(files.first?.lines == nil)
    }

    @Test func readsPathsThatLookLikeOtherFields() throws {
        // A path can hold tabs and spaces, and can start with a colon.
        let paths = ["a\tb\tc.txt", ":100644 100644.txt", "with space.txt", "-\t-\tdash.txt"]
        var fields: [String] = []
        for path in paths { fields += [":100644 100644 \(one) \(two) M", path] }
        for path in paths { fields.append("1\t2\t" + path) }
        let files = try RawDiffParser.parse(output(fields))
        #expect(files.map(\.path) == paths)
        #expect(files.allSatisfy { $0.lines == .init(added: 1, removed: 2) })
    }

    @Test func readsSHA256IDs() throws {
        let long = String(repeating: "a", count: 64)
        let zeros = String(repeating: "0", count: 64)
        let files = try RawDiffParser.parse(output([":000000 100644 \(zeros) \(long) A", "new.txt", "1\t0\tnew.txt"]))
        #expect(files.first?.oldID == nil)
        #expect(files.first?.newID == ObjectID(hex: long))
    }

    @Test func keepsALetterItDoesntKnow() throws {
        let files = try RawDiffParser.parse(output([":100644 100644 \(one) \(two) X", "odd.txt", "1\t0\todd.txt"]))
        #expect(files.first?.status == .other("X"))
        #expect(files.first?.status.letter == "X")
    }

    @Test func readsACommitThatChangesNothing() throws {
        #expect(try RawDiffParser.parse([]) == [])
    }

    @Test(arguments: [
        // Stops in the middle of a field.
        Array(":100644 100644".utf8),
        // A raw record without its path.
        Array(":100644 100644 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 M\0".utf8),
        // Not enough parts in the raw record.
        Array(":100644 M\0a.txt\0".utf8),
        // A file without line counts.
        Array(":100644 100644 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 M\0a.txt\0".utf8),
        // Line counts for another file.
        Array(":100644 100644 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 M\0a.txt\01\t0\tb.txt\0".utf8),
        // Line counts that aren't numbers.
        Array(":100644 100644 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 M\0a.txt\0x\ty\ta.txt\0".utf8),
        // More than it listed.
        Array("1\t0\ta.txt\0".utf8),
    ])
    func rejectsOutputItCantRead(_ output: [UInt8]) {
        #expect(throws: ParseError.self) { try RawDiffParser.parse(output) }
    }

    @Test func splitsAPath() {
        let file = DiffFile(status: .modified, path: "src/ui/view.swift", oldMode: 0, newMode: 0)
        #expect(file.name == "view.swift")
        #expect(file.folder == "src/ui")
        let top = DiffFile(status: .modified, path: "README.md", oldMode: 0, newMode: 0)
        #expect(top.name == "README.md")
        #expect(top.folder == "")
    }
}
