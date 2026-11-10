import Foundation
import GitCore
import TestSupport
import Testing
@testable import CommitGraph

@Suite(.timeLimit(.minutes(1)))
struct CommitGraphTests {
    @Test(arguments: Fixture.History.allCases)
    func readsEveryCommitLikeGit(_ history: Fixture.History) async throws {
        let graph = try await history.graph()
        let commits = try await GitCommits(history.repository())
        #expect(graph.format == history.format)
        #expect(graph.count == commits.oldestFirst.count)
        for id in commits.oldestFirst {
            let position = try #require(graph.position(of: id))
            #expect(graph.id(at: position) == id)
            #expect(graph.commitTime(at: position) == commits.times[id])
            #expect(try graph.parents(of: position).map(graph.id(at:)) == commits.parents[id])
        }
    }

    @Test func findsACommitByFollowingParentsAndGivesUpAtItsLimit() async throws {
        let history = Fixture.History.single
        let graph = try await history.graph()
        let commits = try await GitCommits(history.repository())
        let child = try #require(commits.oldestFirst.last { commits.parents[$0]?.isEmpty == false })
        let newest = try #require(graph.position(of: child))
        let parent = try #require(try graph.parent(of: newest, at: 0))
        #expect(graph.reaches(parent, from: newest, visitLimit: 100) == true)
        #expect(graph.reaches(newest, from: newest, visitLimit: 100) == true)
        #expect(graph.reaches(newest, from: parent, visitLimit: 100) == false)
        #expect(graph.reaches(parent, from: newest, visitLimit: 0) == nil)
    }

    @Test func readsEveryLayerOfAChain() async throws {
        let chain = try await Fixture.History.chain.graph()
        let single = try await Fixture.History.single.graph()
        #expect(chain.paths.count == 3)
        #expect(chain.paths.allSatisfy { $0.contains("/info/commit-graphs/graph-") })
        #expect(single.paths.count == 1)
        #expect(chain.storedCount == single.storedCount)
    }

    /// Checks the generation numbers against their definitions, worked out
    /// from what git says about each commit.
    @Test(arguments: Fixture.History.allCases)
    func readsGenerationNumbers(_ history: Fixture.History) async throws {
        let graph = try await history.graph()
        let commits = try await GitCommits(history.repository())
        #expect(graph.generations == (history == .mixed ? .topologicalLevels : .correctedCommitDates))

        var levels: [ObjectID: UInt64] = [:]
        var correctedDates: [ObjectID: UInt64] = [:]
        for id in commits.oldestFirst {
            let parents = commits.parents[id]!
            levels[id] = 1 + (parents.map { levels[$0]! }.max() ?? 0)
            correctedDates[id] = max(UInt64(commits.times[id]!), parents.map { correctedDates[$0]! + 1 }.max() ?? 0)

            let position = try #require(graph.position(of: id))
            if Int(position) >= graph.storedCount {
                #expect(try graph.generation(at: position) == CommitGraph.infiniteGeneration)
            } else if history == .mixed {
                #expect(try graph.generation(at: position) == levels[id])
            } else {
                #expect(try graph.generation(at: position) == correctedDates[id])
            }
        }
        // The commit dated 1973, whose parent is dated 2100, needs the
        // overflow chunk. The stale graph doesn't have it.
        if history != .stale {
            let dated1973 = try #require(commits.oldestFirst.first { commits.times[$0] == 100_000_000 })
            #expect(correctedDates[dated1973]! - 100_000_000 > UInt64(Int32.max))
        }
    }

    @Test func returnsNilWithoutACommitGraph() async throws {
        let repository = try await Fixture.repository("basic")
        #expect(try CommitGraph(objectsFolder: repository + "/.git/objects", format: .sha1) == nil)
    }

    @Test func findsNothingForIDsItDoesNotHave() async throws {
        let graph = try await Fixture.History.single.graph()
        #expect(graph.position(of: ObjectID(hex: String(repeating: "0", count: 40))!) == nil)
        #expect(graph.position(of: ObjectID(hex: String(repeating: "f", count: 40))!) == nil)
        #expect(graph.position(of: ObjectID(hex: String(repeating: "0", count: 64))!) == nil)
    }

    @Test func addsNewerCommits() async throws {
        let repository = try await Fixture.History.stale.repository()
        let stored = try #require(try CommitGraph(objectsFolder: repository + "/.git/objects", format: .sha1))
        let commits = try await GitCommits(repository)
        let newer = commits.missing(from: stored)
        #expect(newer.count == 7)

        // Newest first, so that some commits come before their parents.
        let graph = try stored.adding(newer.reversed())
        #expect(graph.storedCount == stored.storedCount)
        #expect(graph.count == stored.count + newer.count)
        for commit in newer {
            let position = try #require(graph.position(of: commit.id))
            #expect(Int(position) >= graph.storedCount)
            #expect(graph.id(at: position) == commit.id)
            #expect(graph.commitTime(at: position) == commit.commitTime)
            #expect(try graph.parents(of: position).map(graph.id(at:)) == commit.parents)
        }

        // Commits it already has are skipped.
        #expect(try graph.adding(newer).count == graph.count)
        #expect(try stored.adding([CommitGraph.NewerCommit(id: commits.oldestFirst[0], parents: [], commitTime: 0)]).count == stored.count)
    }

    @Test func refusesNewerCommitsItCannotPlace() async throws {
        let graph = try await Fixture.History.stale.graph()
        let unknown = try #require(ObjectID(hex: String(repeating: "1", count: 40)))
        let commit = try #require(ObjectID(hex: String(repeating: "2", count: 40)))
        #expect(throws: CommitGraphError.missingParent(commit: commit, parent: unknown)) {
            try graph.adding([CommitGraph.NewerCommit(id: commit, parents: [unknown], commitTime: 0)])
        }
        let sha256 = try #require(ObjectID(hex: String(repeating: "3", count: 64)))
        #expect(throws: CommitGraphError.wrongFormat(sha256)) {
            try graph.adding([CommitGraph.NewerCommit(id: sha256, parents: [], commitTime: 0)])
        }
    }
}

/// Opening commit-graph files that are damaged or don't fit together.
@Suite(.timeLimit(.minutes(1)))
struct DamagedCommitGraphTests {
    /// Copies a fixture's commit-graph files into a new objects folder, and
    /// returns that folder.
    func copy(_ history: Fixture.History) async throws -> String {
        let objects = try makeTemporaryFolder() + "/objects"
        try FileManager.default.createDirectory(atPath: objects, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            atPath: try await history.repository() + "/.git/objects/info",
            toPath: objects + "/info"
        )
        return objects
    }

    /// Changes the bytes of a file, which git writes without write permission.
    func change(_ path: String, _ body: (inout [UInt8]) throws -> Void) throws {
        var bytes = try [UInt8](Data(contentsOf: URL(filePath: path)))
        try body(&bytes)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        try Data(bytes).write(to: URL(filePath: path))
    }

    func expectInvalid(_ objects: String, format: ObjectFormat = .sha1, because reason: String) {
        #expect {
            try CommitGraph(objectsFolder: objects, format: format)
        } throws: { error in
            guard case .invalid(_, let actual) = error as? CommitGraphError else { return false }
            return actual.contains(reason)
        }
    }

    @Test func refusesAShortFile() async throws {
        let objects = try await copy(.single)
        try change(objects + "/info/commit-graph") { $0.removeLast($0.count - 30) }
        expectInvalid(objects, because: "too short")
    }

    @Test func refusesAFileThatIsNotACommitGraph() async throws {
        let objects = try await copy(.single)
        try change(objects + "/info/commit-graph") { $0[0] = UInt8(ascii: "X") }
        expectInvalid(objects, because: "doesn't start with CGPH")
    }

    @Test func refusesAnUnknownVersion() async throws {
        let objects = try await copy(.single)
        try change(objects + "/info/commit-graph") { $0[4] = 2 }
        expectInvalid(objects, because: "version 2")
    }

    @Test func refusesTheWrongHashFunction() async throws {
        expectInvalid(try await copy(.single), format: .sha256, because: "doesn't match the repository's sha256")
        expectInvalid(try await copy(.sha256), format: .sha1, because: "doesn't match the repository's sha1")
    }

    @Test func refusesAChunkOutsideTheFile() async throws {
        let objects = try await copy(.single)
        // The offset of the second chunk, in the table after the header.
        try change(objects + "/info/commit-graph") { $0[8 + 12 + 4] = 0xFF }
        expectInvalid(objects, because: "outside the file")
    }

    @Test func refusesAParentOutsideTheGraph() async throws {
        let objects = try await copy(.single)
        try change(objects + "/info/commit-graph") { bytes in
            // Point the first commit's first parent past the last commit.
            let data = try #require(chunkOffset("CDAT", in: bytes))
            let firstParent = data + 20
            bytes.replaceSubrange(firstParent..<firstParent + 4, with: [0x00, 0x10, 0x00, 0x00])
        }
        let graph = try #require(try CommitGraph(objectsFolder: objects, format: .sha1))
        #expect {
            try graph.parents(of: 0)
        } throws: { error in
            guard case .invalid(_, let reason) = error as? CommitGraphError else { return false }
            return reason.contains("has a parent outside the commit-graph")
        }
    }

    @Test func refusesAChainWithAMissingLayer() async throws {
        let objects = try await copy(.chain)
        let folder = objects + "/info/commit-graphs"
        let layers = try String(contentsOfFile: folder + "/commit-graph-chain", encoding: .utf8).split(separator: "\n")
        try FileManager.default.removeItem(atPath: folder + "/graph-\(layers[1]).graph")
        #expect(throws: CommitGraphError.cannotRead(path: folder + "/graph-\(layers[1]).graph", errorNumber: ENOENT)) {
            try CommitGraph(objectsFolder: objects, format: .sha1)
        }
    }

    @Test func refusesAChainInTheWrongOrder() async throws {
        let objects = try await copy(.chain)
        let chain = objects + "/info/commit-graphs/commit-graph-chain"
        try change(chain) { bytes in
            let lines = bytes.split(separator: UInt8(ascii: "\n"))
            bytes = Array(lines.reversed().joined(separator: [UInt8(ascii: "\n")])) + [UInt8(ascii: "\n")]
        }
        expectInvalid(objects, because: "don't match the chain")
    }

    @Test func refusesAChainLineThatIsNotAHash() async throws {
        let objects = try await copy(.chain)
        try change(objects + "/info/commit-graphs/commit-graph-chain") { $0.insert(contentsOf: Array("nope\n".utf8), at: 0) }
        expectInvalid(objects, because: "Line 1 isn't a sha1 hash")
    }

    @Test func treatsAnEmptyChainAsNoCommitGraph() async throws {
        let objects = try await copy(.chain)
        try change(objects + "/info/commit-graphs/commit-graph-chain") { $0 = [] }
        #expect(try CommitGraph(objectsFolder: objects, format: .sha1) == nil)
    }

    /// Finds a chunk in a commit-graph file's table of chunks.
    func chunkOffset(_ id: String, in bytes: [UInt8]) -> Int? {
        let id = Array(id.utf8)
        for index in 0..<Int(bytes[6]) {
            let entry = 8 + index * 12
            guard Array(bytes[entry..<entry + 4]) == id else { continue }
            return bytes[entry + 4..<entry + 12].reduce(0) { $0 << 8 | Int($1) }
        }
        return nil
    }
}
