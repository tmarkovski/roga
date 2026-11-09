import Testing
@testable import GitCore

struct CommitLineCountsParserTests {
    let one = "1111111111111111111111111111111111111111"
    let two = "2222222222222222222222222222222222222222"

    /// Reads lines as git prints them, each without its newline.
    func parse(_ lines: [String]) throws -> [ObjectID: DiffFile.LineCounts] {
        var parser = CommitLineCountsParser()
        for line in lines {
            try parser.read(Array(line.utf8)[...])
        }
        return parser.counts
    }

    @Test func addsUpEveryFileOfEachCommit() throws {
        let counts = try parse([
            one,
            "6\t0\tmoved.txt",
            "1\t0\t\"src/a\\ttab.txt\"",
            "-\t-\timage.bin",
            two,
            "1\t1\tkind.txt",
            "1\t0\tmoved.txt => lib/moved.txt",
            "0\t1\tsrc/gone.txt",
        ])
        #expect(counts == [
            try #require(ObjectID(hex: one)): DiffFile.LineCounts(added: 7, removed: 0),
            try #require(ObjectID(hex: two)): DiffFile.LineCounts(added: 2, removed: 2),
        ])
    }

    @Test func countsACommitThatOnlyChangedBinaryFilesAsNoLines() throws {
        let counts = try parse([one, "-\t-\timage.bin"])
        #expect(counts[try #require(ObjectID(hex: one))] == DiffFile.LineCounts(added: 0, removed: 0))
    }

    @Test func readsSHA256Commits() throws {
        let long = String(repeating: "a", count: 64)
        let counts = try parse([long, "3\t4\tfile.txt"])
        #expect(counts[try #require(ObjectID(hex: long))] == DiffFile.LineCounts(added: 3, removed: 4))
    }

    @Test func refusesCountsBeforeAnyCommit() {
        #expect(throws: ParseError.self) { try parse(["1\t2\tfile.txt"]) }
    }

    @Test func refusesALineItCantRead() {
        #expect(throws: ParseError.self) { try parse([one, "1\tfile.txt"]) }
        #expect(throws: ParseError.self) { try parse([one, "x\t2\tfile.txt"]) }
        #expect(throws: ParseError.self) { try parse(["not a commit"]) }
    }
}
