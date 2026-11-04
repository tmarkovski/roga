import Testing
@testable import GitCore

struct SubmoduleListParserTests {
    func output(_ lines: [String]) -> [UInt8] {
        Array(lines.map { $0 + "\0" }.joined().utf8)
    }

    let id = String(repeating: "a", count: 40)

    @Test func keepsOnlyTheSubmodules() throws {
        let paths = try SubmoduleListParser.parse(output([
            "100644 \(id) 0\t.gitmodules",
            "100755 \(id) 0\tbuild.sh",
            "160000 \(id) 0\tthird_party/longhand",
            "120000 \(id) 0\tlink",
            "160000 \(id) 0\tvendor/my lib",
        ]))
        #expect(paths == ["third_party/longhand", "vendor/my lib"])
    }

    @Test func countsASubmoduleInAConflictOnce() throws {
        let paths = try SubmoduleListParser.parse(output([
            "160000 \(id) 1\tvendor/lib",
            "160000 \(id) 2\tvendor/lib",
            "160000 \(id) 3\tvendor/lib",
        ]))
        #expect(paths == ["vendor/lib"])
    }

    @Test func aFileNamedLikeAModeIsntASubmodule() throws {
        let paths = try SubmoduleListParser.parse(output(["100644 \(id) 0\t160000 lib"]))
        #expect(paths.isEmpty)
    }

    @Test func nothingListedHasNoSubmodules() throws {
        #expect(try SubmoduleListParser.parse([]).isEmpty)
    }

    @Test func aSubmoduleWithoutAPathIsAnError() {
        #expect(throws: ParseError.self) {
            try SubmoduleListParser.parse(output(["160000 \(id) 0"]))
        }
    }
}
