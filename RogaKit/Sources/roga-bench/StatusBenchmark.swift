import Foundation
import GitCore
import GitRunner
import RepositoryEngine

/// Measures listing a worktree's uncommitted files, as the app does for the row
/// in history and for the panel, against the roadmap's target of 300 ms.
struct StatusBenchmark {
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
        var count = 0
        func report(_ title: String, _ body: () async throws -> Int) async rethrows {
            var times: [Double] = []
            for _ in 0..<runs {
                let start = ContinuousClock.now
                count = try await body()
                let duration = start.duration(to: .now)
                times.append(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
            }
            times.sort()
            print("\(title): median \(String(format: "%.0f", times[times.count / 2])) ms, slowest \(String(format: "%.0f", times[times.count - 1])) ms, \(count) files")
        }
        try await report("Counting files, for the row") { try await session.status(in: worktree).fileCount }
        try await report("Listing them with line counts, for the panel") { try await session.changes(in: worktree).fileCount }
    }
}
