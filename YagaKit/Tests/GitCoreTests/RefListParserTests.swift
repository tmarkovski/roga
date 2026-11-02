import Testing
@testable import GitCore

struct RefListParserTests {
    let commit = "da9ff97390adfc8a4a4b4c0f0a1481c9084145d5"
    let tag = "a29ac133f920c06cbb0d2c96475d9067ace72ca7"
    let tree = "407153ae6640b677b6d83c08329048174e634843"

    func line(_ fields: String...) -> String {
        fields.joined(separator: "\0") + "\n"
    }

    @Test func readsEveryKindOfRef() throws {
        let output = line("refs/heads/main", commit, "commit", "", "", "*", "")
            + line("refs/remotes/origin/HEAD", commit, "commit", "", "", " ", "refs/remotes/origin/main")
            + line("refs/remotes/origin/main", commit, "commit", "", "", " ", "")
            + line("refs/tags/v0.1", tag, "tag", commit, "commit", " ", "")
            + line("refs/tags/tree", tree, "tree", "", "", " ", "")
            + line("refs/stash", commit, "commit", "", "", " ", "")
        let result = try RefListParser.parse(Array(output.utf8))
        let id = ObjectID(hex: commit)

        #expect(result.currentBranch == "refs/heads/main")
        #expect(result.refs == [
            Ref(name: "refs/heads/main", target: id!, commit: id),
            Ref(name: "refs/remotes/origin/HEAD", target: id!, commit: id, symbolicTarget: "refs/remotes/origin/main"),
            Ref(name: "refs/remotes/origin/main", target: id!, commit: id),
            Ref(name: "refs/tags/v0.1", target: ObjectID(hex: tag)!, commit: id),
            Ref(name: "refs/tags/tree", target: ObjectID(hex: tree)!, commit: nil),
            Ref(name: "refs/stash", target: id!, commit: id),
        ])
        #expect(result.refs.map(\.kind) == [.branch, .remoteBranch, .remoteBranch, .tag, .tag, .other])
        #expect(result.refs.map(\.shortName) == ["main", "origin/HEAD", "origin/main", "v0.1", "tree", "stash"])
    }

    @Test func readsNoRefs() throws {
        let result = try RefListParser.parse([])
        #expect(result.refs.isEmpty)
        #expect(result.currentBranch == nil)
    }

    @Test func rejectsAnotherFormat() {
        #expect(throws: ParseError.self) {
            try RefListParser.parse(Array("refs/heads/main \(commit)\n".utf8))
        }
    }
}
