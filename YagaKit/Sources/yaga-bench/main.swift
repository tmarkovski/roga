// Benchmarks for the performance targets in ROADMAP.md, run against the real
// modules. Each benchmark is added with the code it measures.
//
// Usage:
//   yaga-bench history <repository> [--sort date|topological] [--runs N] [--verify]
//
// The history benchmark needs a repository with a commit-graph file. Only
// commits matter to it, so a clone of Linux without trees or files is enough:
//
//   git clone --filter=tree:0 --no-checkout https://github.com/torvalds/linux.git bench-repos/linux-commits
//   git -C bench-repos/linux-commits commit-graph write --reachable

import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "history":
        try await HistoryBenchmark(arguments: Array(arguments.dropFirst())).run()
    default:
        print("Usage: yaga-bench history <repository> [--sort date|topological] [--runs N] [--verify]")
        exit(2)
    }
} catch {
    print("yaga-bench: \(error)")
    exit(1)
}

struct UsageError: Error, CustomStringConvertible {
    var description: String
}
