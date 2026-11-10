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

/// Reading which commit the index records for each submodule.
struct SubmoduleRecordedParserTests {
    func output(_ lines: [String]) -> [UInt8] {
        Array(lines.map { $0 + "\0" }.joined().utf8)
    }

    let first = String(repeating: "a", count: 40)
    let second = String(repeating: "b", count: 40)
    let third = String(repeating: "c", count: 40)

    @Test func eachSubmoduleHasTheCommitItsRecordedAt() throws {
        let commits = try SubmoduleListParser.recorded(output([
            "100644 \(first) 0\t.gitmodules",
            "160000 \(second) 0\tthird_party/longhand",
            "100644 \(first) 0\tvendor/my lib/readme.md",
            "160000 \(third) 0\tvendor/my lib",
        ]))
        #expect(commits == ["third_party/longhand": ObjectID(hex: second)!, "vendor/my lib": ObjectID(hex: third)!])
    }

    @Test func aSubmoduleInAConflictHasOurCommit() throws {
        let commits = try SubmoduleListParser.recorded(output([
            "160000 \(first) 1\tvendor/lib",
            "160000 \(second) 2\tvendor/lib",
            "160000 \(third) 3\tvendor/lib",
        ]))
        #expect(commits == ["vendor/lib": ObjectID(hex: second)!])
        // Without our side, as when we deleted it, it's whichever comes first.
        let theirs = try SubmoduleListParser.recorded(output(["160000 \(first) 1\tvendor/lib", "160000 \(third) 3\tvendor/lib"]))
        #expect(theirs == ["vendor/lib": ObjectID(hex: first)!])
    }

    @Test func aSubmoduleWithoutACommitIsAnError() {
        #expect(throws: ParseError.self) {
            try SubmoduleListParser.recorded(output(["160000 not-a-commit 0\tvendor/lib"]))
        }
        #expect(throws: ParseError.self) {
            try SubmoduleListParser.recorded(output(["160000 \(first) 0"]))
        }
    }

    @Test func nothingListedRecordsNothing() throws {
        #expect(try SubmoduleListParser.recorded([]).isEmpty)
    }
}

/// Reading what `.gitmodules` and git's settings say about submodules.
struct SubmoduleConfigParserTests {
    func output(_ entries: [String]) -> [UInt8] {
        Array(entries.map { $0 + "\0" }.joined().utf8)
    }

    @Test func eachSubmoduleHasItsPathAndItsURL() throws {
        let modules = try SubmoduleConfigParser.parse(output([
            "submodule.vendor/parser.path\nvendor/parser",
            "submodule.vendor/parser.url\nhttps://example.com/tools/parser.git",
            "submodule.lexer.url\n../lexer.git",
            "submodule.lexer.path\nlib/my lexer",
        ]))
        #expect(modules == [
            "vendor/parser": .init(path: "vendor/parser", url: "https://example.com/tools/parser.git"),
            "lexer": .init(path: "lib/my lexer", url: "../lexer.git"),
        ])
    }

    @Test func aNameCanHaveDotsInIt() throws {
        let modules = try SubmoduleConfigParser.parse(output([
            "submodule.tools.lexer.v2.path\nlib/lexer",
            "submodule.a.url.url\nhttps://example.com/a.git",
        ]))
        #expect(modules == ["tools.lexer.v2": .init(path: "lib/lexer"), "a.url": .init(url: "https://example.com/a.git")])
    }

    @Test func aSettingGivenTwiceKeepsItsLastValue() throws {
        let modules = try SubmoduleConfigParser.parse(output([
            "submodule.lexer.url\nhttps://example.com/first.git",
            "submodule.lexer.url\nhttps://example.com/second.git",
        ]))
        #expect(modules == ["lexer": .init(url: "https://example.com/second.git")])
    }

    @Test func aSettingWithoutAValueSaysNothing() throws {
        #expect(try SubmoduleConfigParser.parse(output(["submodule.lexer.path"])).isEmpty)
        #expect(try SubmoduleConfigParser.parse([]).isEmpty)
    }

    @Test func anotherSettingIsAnError() {
        #expect(throws: ParseError.self) {
            try SubmoduleConfigParser.parse(output(["remote.origin.url\nhttps://example.com/a.git"]))
        }
        #expect(throws: ParseError.self) {
            try SubmoduleConfigParser.parse(output(["submodule.lexer.update\nnone"]))
        }
    }
}
