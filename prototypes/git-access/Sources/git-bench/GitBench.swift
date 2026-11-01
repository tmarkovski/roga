import ArgumentParser
import Foundation

@main
struct GitBench: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "git-bench",
        abstract: "Compares ways for yaga to read a Git repository.",
        subcommands: [LogCLI.self, LogLibgit2.self, LogGraph.self, Status.self, Diff.self, VerifyGraph.self, Render.self]
    )
}

struct CommonOptions: ParsableArguments {
    @Option(help: "Path to the repository to benchmark.")
    var repo: String

    @Option(help: "How many times to repeat each measurement.")
    var runs: Int = 3

    @Option(help: "How many commit rows fit on one screen.")
    var screenRows: Int = 100

    var repoPath: String { URL(fileURLWithPath: repo).standardizedFileURL.path }
}

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
