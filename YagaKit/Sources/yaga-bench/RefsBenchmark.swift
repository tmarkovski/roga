import Foundation
import GitCore
import GitRunner
import RepositoryEngine

/// Measures reading what the refs panel lists, as the app does when the panel
/// shows and each time yaga becomes active.
struct RefsBenchmark {
    var worktree: String
    var runs = 10

    init(arguments: [String]) throws {
        var arguments = arguments[...]
        guard let worktree = arguments.popFirst() else { throw UsageError(description: "Which worktree?") }
        self.worktree = worktree
        while let option = arguments.popFirst() {
            guard option == "--runs", let value = arguments.popFirst().flatMap({ Int($0) }) else {
                throw UsageError(description: "Unknown option \(option)")
            }
            runs = value
        }
    }

    func run() async throws {
        let installation = try await GitInstallation.locate()
        let session = try await RepositorySession.open(containing: worktree, git: Git(installation: installation))
        var times: [Double] = []
        var details = RefDetails()
        for _ in 0..<runs {
            let start = ContinuousClock.now
            details = try await session.refDetails(in: worktree)
            let duration = start.duration(to: .now)
            times.append(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
        }
        times.sort()
        print("Reading the lists: median \(String(format: "%.0f", times[times.count / 2])) ms, slowest \(String(format: "%.0f", times[times.count - 1])) ms")
        let remoteBranches = details.remotes.reduce(0) { $0 + $1.branches.count }
        print("\(details.branches.count) branches, \(details.remotes.count) remotes with \(remoteBranches) branches, \(details.tags.count) tags, \(details.stashes.count) stashes")
    }
}
