import Testing
@testable import GitCore

struct RefDetailsParserTests {
    let commit = "da9ff97390adfc8a4a4b4c0f0a1481c9084145d5"
    let other = "a29ac133f920c06cbb0d2c96475d9067ace72ca7"

    func line(_ fields: String...) -> [UInt8] {
        Array((fields.joined(separator: "\0") + "\n").utf8)
    }

    @Test func readsBranchesWithAndWithoutAnUpstream() throws {
        let id = try #require(ObjectID(hex: commit))
        let output = line("refs/heads/main", commit, "1700000000", "refs/remotes/origin/main", "ahead 4", "")
            + line("refs/heads/behind", commit, "1700000000", "refs/remotes/origin/behind", "behind 2", "1 3")
            + line("refs/heads/both", commit, "1700000000", "refs/remotes/origin/both", "ahead 1, behind 12", "1 3")
            + line("refs/heads/even", commit, "1700000000", "refs/remotes/origin/even", "", "0 0")
            + line("refs/heads/gone", commit, "1700000000", "refs/remotes/origin/gone", "gone", "2 5")
            + line("refs/heads/none", commit, "", "", "", "3 0")
        let entries = try BranchListParser.parse(output)

        #expect(entries.map(\.upstream) == [
            "refs/remotes/origin/main", "refs/remotes/origin/behind", "refs/remotes/origin/both", "refs/remotes/origin/even", nil, nil,
        ])
        #expect(entries.map(\.upstreamCounts) == [
            .init(ahead: 4, behind: 0), .init(ahead: 0, behind: 2), .init(ahead: 1, behind: 12), .init(ahead: 0, behind: 0), nil, nil,
        ])
        #expect(entries.map(\.baseCounts) == [
            nil, .init(ahead: 1, behind: 3), .init(ahead: 1, behind: 3), .init(ahead: 0, behind: 0), .init(ahead: 2, behind: 5), .init(ahead: 3, behind: 0),
        ])
        #expect(entries[0].tip == id)
        #expect(entries[0].date == 1_700_000_000)
        #expect(entries[5].date == nil)
    }

    @Test func refusesABranchItCantRead() {
        #expect(throws: ParseError.self) { try BranchListParser.parse(line("refs/heads/a", commit)) }
        #expect(throws: ParseError.self) { try BranchListParser.parse(line("refs/heads/a", "nope", "", "", "", "")) }
        #expect(throws: ParseError.self) { try BranchListParser.parse(line("refs/heads/a", commit, "", "refs/remotes/o/a", "sideways 2", "")) }
        #expect(throws: ParseError.self) { try BranchListParser.parse(line("refs/heads/a", commit, "", "", "", "many")) }
    }

    @Test func asksForTheCountsOnlyWhenThereIsSomethingToCompareWith() throws {
        let id = try #require(ObjectID(hex: commit))
        #expect(BranchListParser.format(comparingWith: id).hasSuffix("%00%(ahead-behind:\(commit))"))
        #expect(BranchListParser.format(comparingWith: nil).hasSuffix("%00"))
    }

    @Test func readsRemoteBranchesAndEveryKindOfTag() throws {
        let id = try #require(ObjectID(hex: commit))
        let target = try #require(ObjectID(hex: other))
        let output = line("refs/remotes/origin/HEAD", commit, "commit", "", "", "1700000000", "refs/remotes/origin/main")
            + line("refs/remotes/origin/main", commit, "commit", "", "", "1700000000", "")
            + line("refs/tags/light", commit, "commit", "", "", "1700000001", "")
            + line("refs/tags/annotated", commit, "tag", "commit", other, "1700000002", "")
            + line("refs/tags/on-a-tree", commit, "tag", "tree", other, "", "")
            + line("refs/tags/on-a-tag", commit, "tag", "tag", other, "1700000003", "")
        let result = try RemoteAndTagListParser.parse(output)

        // origin/HEAD isn't a branch of its own.
        #expect(result.remoteBranches == [RemoteBranchDetails(name: "refs/remotes/origin/main", tip: id, date: 1_700_000_000)])
        #expect(result.tags == [
            TagDetails(name: "refs/tags/light", commit: id, date: 1_700_000_001),
            TagDetails(name: "refs/tags/annotated", commit: target, date: 1_700_000_002),
            TagDetails(name: "refs/tags/on-a-tree"),
            TagDetails(name: "refs/tags/on-a-tag", date: 1_700_000_003),
        ])
    }

    @Test func readsTheFirstURLOfEachRemote() throws {
        let output = "remote.origin.url\nhttps://github.com/a/b.git\0remote.origin.url\nhttps://mirror.example.com/a/b.git\0remote.my.fork.url\ngit@example.com:me/b.git\0"
        #expect(try RemoteListParser.parse(Array(output.utf8)) == [
            "origin": "github.com/a/b.git",
            "my.fork": "example.com/me/b.git",
        ])
        #expect(try RemoteListParser.parse([]) == [:])
        #expect(throws: ParseError.self) { try RemoteListParser.parse(Array("nonsense\0".utf8)) }
    }

    @Test(arguments: [
        ("https://github.com/torvalds/linux.git", "github.com/torvalds/linux.git"),
        ("https://ana:secret-token@github.com/a/b.git", "github.com/a/b.git"),
        ("https://x-access-token:a@b@github.com/a/b.git", "github.com/a/b.git"),
        ("ssh://git@example.com:2222/a/b.git", "example.com:2222/a/b.git"),
        ("git@github.com:a/b.git", "github.com/a/b.git"),
        ("github.com:a/b.git", "github.com/a/b.git"),
        ("git@github.com:/a/b.git", "github.com/a/b.git"),
        ("file:///srv/git/b.git", "/srv/git/b.git"),
        ("/srv/git/b.git", "/srv/git/b.git"),
        ("../sibling", "../sibling"),
        ("./odd:name", "./odd:name"),
    ])
    func showsARemotesAddressWithoutItsCredentials(url: String, shown: String) {
        #expect(RemoteAddress.shown(url) == shown)
    }

    @Test func putsBranchesUnderTheLongestRemoteNameTheyStartWith() throws {
        let id = try #require(ObjectID(hex: commit))
        func branch(_ name: String) -> RemoteBranchDetails {
            RemoteBranchDetails(name: "refs/remotes/" + name, tip: id)
        }
        let remotes = RemoteDetails.grouping(
            [branch("origin/main"), branch("origin/agent/fix"), branch("team/one/main"), branch("team/two"), branch("removed/old")],
            addresses: ["origin": "a", "team/one": "b", "team": "c", "empty": "d"]
        )
        #expect(remotes.map(\.name) == ["empty", "origin", "removed", "team", "team/one"])
        #expect(remotes.map(\.address) == ["d", "a", nil, "c", "b"])
        #expect(remotes.map { $0.branches.map(\.shortName) } == [[], ["main", "agent/fix"], ["old"], ["two"], ["main"]])
    }

    @Test func readsStashesFromTheLatestToTheOldest() throws {
        let id = try #require(ObjectID(hex: commit))
        let older = try #require(ObjectID(hex: other))
        let stashes = try StashListParser.parse(line(commit, "1700000002", "WIP on main: 5405371 Fix it") + line(other, "1700000001", "On main: try this"))
        #expect(stashes == [
            StashDetails(position: 0, commit: id, date: 1_700_000_002, message: "WIP on main: 5405371 Fix it"),
            StashDetails(position: 1, commit: older, date: 1_700_000_001, message: "On main: try this"),
        ])
        #expect(stashes.map(\.name) == ["stash@{0}", "stash@{1}"])
        #expect(try StashListParser.parse([]).isEmpty)
        #expect(throws: ParseError.self) { try StashListParser.parse(line("nope", "1", "x")) }
    }

    @Test func findsTheMainBranch() throws {
        let id = try #require(ObjectID(hex: commit))
        func ref(_ name: String, target: String? = nil) -> Ref { Ref(name: name, target: id, symbolicTarget: target) }
        let originHead = ref("refs/remotes/origin/HEAD", target: "refs/remotes/origin/trunk")
        let originTrunk = ref("refs/remotes/origin/trunk")

        // The local branch of the name origin's HEAD gives.
        #expect(RefList(refs: [ref("refs/heads/main"), ref("refs/heads/trunk"), originHead, originTrunk]).mainBranch?.name == "refs/heads/trunk")
        // Without one, origin's own.
        #expect(RefList(refs: [ref("refs/heads/main"), originHead, originTrunk]).mainBranch?.name == "refs/remotes/origin/trunk")
        // Origin before any other remote.
        let upstreamHead = ref("refs/remotes/another/HEAD", target: "refs/remotes/another/dev")
        #expect(RefList(refs: [upstreamHead, ref("refs/remotes/another/dev"), originHead, originTrunk]).mainBranch?.name == "refs/remotes/origin/trunk")
        // Another remote, when it's the only one that says.
        #expect(RefList(refs: [upstreamHead, ref("refs/remotes/another/dev")]).mainBranch?.name == "refs/remotes/another/dev")
        // Without a remote's HEAD.
        #expect(RefList(refs: [ref("refs/heads/master"), ref("refs/heads/main")]).mainBranch?.name == "refs/heads/main")
        #expect(RefList(refs: [ref("refs/heads/master")]).mainBranch?.name == "refs/heads/master")
        #expect(RefList(refs: [ref("refs/heads/develop")]).mainBranch == nil)
    }

    @Test(arguments: [
        ("git@github.com:torvalds/linux.git", "torvalds"),
        ("https://github.com/Acme/api.git", "Acme"),
        ("https://user:secret@github.com/acme/api", "acme"),
        ("ssh://git@github.com/acme/api.git", "acme"),
        ("ssh://git@host:2222/acme/api.git", "acme"),
        ("gh:acme/api", "acme"),
        ("https://gitlab.com/group/subgroup/project.git", "group"),
    ])
    func ownerOfARemote(url: String, owner: String) {
        #expect(RemoteAddress.owner(url) == owner)
    }

    @Test(arguments: [
        "/Users/me/git/api.git",
        "../api.git",
        "some/relative/path",
        "file:///Users/me/git/api.git",
        "host:api.git",
        "https://example.com/api.git",
        "https://example.com",
        "",
    ])
    func remotesWithoutAnOwner(url: String) {
        #expect(RemoteAddress.owner(url) == nil)
    }
}
