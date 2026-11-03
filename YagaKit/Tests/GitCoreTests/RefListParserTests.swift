import Testing
@testable import GitCore

struct RefListParserTests {
    let commit = "da9ff97390adfc8a4a4b4c0f0a1481c9084145d5"
    let tag = "a29ac133f920c06cbb0d2c96475d9067ace72ca7"

    func line(_ fields: String...) -> String {
        fields.joined(separator: "\0") + "\n"
    }

    @Test func readsEveryKindOfRef() throws {
        let output = line("refs/heads/main", commit, "*", "", "refs/remotes/origin/main")
            + line("refs/remotes/origin/HEAD", commit, " ", "refs/remotes/origin/main", "")
            + line("refs/remotes/origin/main", commit, " ", "", "")
            + line("refs/tags/v0.1", tag, " ", "", "")
            + line("refs/stash", commit, " ", "", "")
        let result = try RefListParser.parse(Array(output.utf8))
        let id = try #require(ObjectID(hex: commit))
        let tagID = try #require(ObjectID(hex: tag))

        #expect(result.currentBranch == "refs/heads/main")
        #expect(result.refs == [
            Ref(name: "refs/heads/main", target: id, upstream: "refs/remotes/origin/main"),
            Ref(name: "refs/remotes/origin/HEAD", target: id, symbolicTarget: "refs/remotes/origin/main"),
            Ref(name: "refs/remotes/origin/main", target: id),
            Ref(name: "refs/tags/v0.1", target: tagID),
            Ref(name: "refs/stash", target: id),
        ])
        #expect(result.refs.map(\.kind) == [.branch, .remoteBranch, .remoteBranch, .tag, .other])
        #expect(result.refs.map(\.shortName) == ["main", "origin/HEAD", "origin/main", "v0.1", "stash"])
        // Until show-ref says otherwise, a tag leads to its own object.
        #expect(result.refs[3].peeled == tagID)
    }

    func ref(_ name: String, upstream: String?) throws -> Ref {
        Ref(name: name, target: try #require(ObjectID(hex: commit)), upstream: upstream)
    }

    @Test func knowsAnUpstreamOfTheSameName() throws {
        #expect(try ref("refs/heads/main", upstream: "refs/remotes/origin/main").upstreamOfSameName == "refs/remotes/origin/main")
        #expect(try ref("refs/heads/tm/fix", upstream: "refs/remotes/origin/tm/fix").upstreamOfSameName == "refs/remotes/origin/tm/fix")
    }

    @Test func knowsAnUpstreamOfAnotherName() throws {
        #expect(try ref("refs/heads/main", upstream: nil).upstreamOfSameName == nil)
        #expect(try ref("refs/heads/fix", upstream: "refs/remotes/origin/tm/fix").upstreamOfSameName == nil)
        #expect(try ref("refs/heads/fix", upstream: "refs/remotes/origin/fixes").upstreamOfSameName == nil)
        // This one tracks a local branch rather than a remote's.
        #expect(try ref("refs/heads/fix", upstream: "refs/heads/other/fix").upstreamOfSameName == nil)
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
