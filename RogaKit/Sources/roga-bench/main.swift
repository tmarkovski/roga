// Benchmarks for the performance targets in ROADMAP.md, run against the real
// modules. Each benchmark is added with the code it measures.
//
// Usage:
//   roga-bench history <repository> [--sort date|topological] [--runs N] [--verify] [--cold [--parts]]
//   roga-bench commit-graph <repository>
//   roga-bench diff [--lines N] [--line-length N] [--jumps N]
//   roga-bench status <worktree> [--runs N]
//   roga-bench refs <worktree> [--runs N]
//
// The history benchmark orders history from HEAD with the commit-graph reader
// alone, then through a repository session from every branch, remote branch
// and tag, as the app does. It needs a repository with a commit-graph file.
// Only commits matter to it, so a clone of Linux without trees or files is
// enough:
//
//   git clone --filter=tree:0 --no-checkout https://github.com/torvalds/linux.git bench-repos/linux-commits
//   git -C bench-repos/linux-commits commit-graph write --reachable
//
// With --cold, it loads history once through a session and reports how many
// pages each step read from disk. Only the first load after emptying the disk
// cache is cold, so run it right after `sudo purge`:
//
//   sudo purge && RogaKit/.build/release/roga-bench history bench-repos/linux-commits --cold
//
// With --parts as well, it takes the steps one at a time instead of the way
// the app overlaps them, to show what each one costs.
//
// The commit-graph benchmark brings the repository's commit-graph files up to
// date the way the app does, and writes to the repository, so give it a copy.
// On APFS, cp -c makes one without using much disk.
//
// The diff benchmark needs no repository, because it generates a patch. It
// opens a window for a few seconds, without taking the keyboard.
//
// The status benchmark lists a worktree's uncommitted files the way the app
// does. It only reads the worktree, and it needs one with its files checked
// out, which the clone for the history benchmark doesn't have.
//
// The refs benchmark reads what the refs panel lists. It only reads the
// repository, so the clone for the history benchmark works.

import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "history":
        try await HistoryBenchmark(arguments: Array(arguments.dropFirst())).run()
    case "commit-graph":
        try await CommitGraphBenchmark(arguments: Array(arguments.dropFirst())).run()
    case "diff":
        try await DiffBenchmark(arguments: Array(arguments.dropFirst())).run()
    case "status":
        try await StatusBenchmark(arguments: Array(arguments.dropFirst())).run()
    case "refs":
        try await RefsBenchmark(arguments: Array(arguments.dropFirst())).run()
    default:
        print("Usage: roga-bench history <repository> [--sort date|topological] [--runs N] [--verify] [--cold [--parts]]")
        print("       roga-bench commit-graph <repository>")
        print("       roga-bench diff [--lines N] [--line-length N] [--jumps N]")
        print("       roga-bench status <worktree> [--runs N]")
        print("       roga-bench refs <worktree> [--runs N]")
        exit(2)
    }
} catch {
    print("roga-bench: \(error)")
    exit(1)
}

struct UsageError: Error, CustomStringConvertible {
    var description: String
}
