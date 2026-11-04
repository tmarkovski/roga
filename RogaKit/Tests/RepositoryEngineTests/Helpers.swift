import CommitGraph
import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

func openSession(_ path: String) async throws -> RepositorySession {
    try await RepositorySession.open(containing: path, git: try await TestGit.make())
}

/// Loads history to the end, and returns every snapshot the session yielded.
func loadHistory(
    _ session: RepositorySession,
    sort: HistoryOrder.Sort = .topological,
    firstRows: Int = 200
) async throws -> [History] {
    var snapshots: [History] = []
    for try await history in session.history(sort: sort, firstRows: firstRows) {
        snapshots.append(history)
    }
    return snapshots
}

/// The order `git log` shows the commits in, starting from the same commits
/// as Roga's history.
func gitOrder(_ sort: HistoryOrder.Sort, in repository: String) async throws -> [ObjectID] {
    let option = sort == .date ? "--date-order" : "--topo-order"
    let text = try await runGit("log", option, "--format=%H", "HEAD", "--branches", "--remotes", "--tags", in: repository)
    return try text.split(separator: "\n").map { try #require(ObjectID(hex: $0)) }
}

extension History {
    var ids: [ObjectID] { rows.map { graph.id(at: $0) } }
}

@discardableResult
func runGit(_ arguments: String..., in folder: String) async throws -> String {
    try await TestGit.make().text(GitCommand(arguments, in: folder))
}

/// Copies a test repository into a new folder, so a test can change it.
/// The copy has its own objects and no commit-graph file.
func copyRepository(_ repository: String) async throws -> String {
    let copy = try makeTemporaryFolder() + "/" + (repository as NSString).lastPathComponent
    try await runGit("clone", "--quiet", "--no-local", repository, copy, in: repository)
    return copy
}

/// Makes a new, empty folder for a test, and returns its real path.
func makeTemporaryFolder() throws -> String {
    let folder = FileManager.default.temporaryDirectory.appending(path: "roga-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let resolved = try #require(realpath(folder.path(percentEncoded: false), nil))
    defer { free(resolved) }
    return String(cString: resolved)
}
