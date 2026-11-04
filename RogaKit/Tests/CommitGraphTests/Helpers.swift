import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import CommitGraph

/// What git says about every commit in a repository.
struct GitCommits {
    var times: [ObjectID: Int64] = [:]
    var parents: [ObjectID: [ObjectID]] = [:]
    /// Every commit, each one after its parents.
    var oldestFirst: [ObjectID] = []

    init(_ repository: String) async throws {
        let git = try await TestGit.make()
        let text = try await git.text(GitCommand(
            "log", "--all", "--topo-order", "--reverse", "--format=%H %ct %P", in: repository
        ))
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            let id = try #require(ObjectID(hex: fields[0]))
            let time = try #require(Int64(fields[1]))
            times[id] = time
            parents[id] = try fields.dropFirst(2).map { try #require(ObjectID(hex: $0)) }
            oldestFirst.append(id)
        }
    }

    /// The commits that `graph` doesn't have, for adding as newer commits.
    func missing(from graph: CommitGraph) -> [CommitGraph.NewerCommit] {
        oldestFirst
            .filter { graph.position(of: $0) == nil }
            .map { CommitGraph.NewerCommit(id: $0, parents: parents[$0]!, commitTime: times[$0]!) }
    }
}

extension Fixture.History {
    var format: ObjectFormat { self == .sha256 ? .sha256 : .sha1 }

    /// Opens the repository's commit-graph, adding the commits that are
    /// newer than its file.
    func graph() async throws -> CommitGraph {
        let repository = try await repository()
        let graph = try #require(try CommitGraph(objectsFolder: repository + "/.git/objects", format: format))
        guard self == .stale else { return graph }
        return try await graph.adding(GitCommits(repository).missing(from: graph))
    }
}

/// The commits that names such as branches and tags point to, in order.
func resolve(_ names: [String], in repository: String) async throws -> [ObjectID] {
    let git = try await TestGit.make()
    let text = try await git.text(GitCommand(["rev-parse"] + names.map { $0 + "^{commit}" }, in: repository))
    return try text.split(separator: "\n").map { try #require(ObjectID(hex: $0)) }
}

/// The order `git log` shows the commits reachable from `names` in.
func gitOrder(_ sort: HistoryOrder.Sort, from names: [String], in repository: String) async throws -> [ObjectID] {
    let git = try await TestGit.make()
    let option = sort == .date ? "--date-order" : "--topo-order"
    let text = try await git.text(GitCommand(["log", option, "--format=%H"] + names, in: repository))
    return try text.split(separator: "\n").map { try #require(ObjectID(hex: $0)) }
}

/// Makes a new, empty folder for a test, and returns its real path.
func makeTemporaryFolder() throws -> String {
    let folder = FileManager.default.temporaryDirectory.appending(path: "roga-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let resolved = try #require(realpath(folder.path(percentEncoded: false), nil))
    defer { free(resolved) }
    return String(cString: resolved)
}
