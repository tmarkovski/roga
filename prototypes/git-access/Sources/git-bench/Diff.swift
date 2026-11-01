import ArgumentParser
import Clibgit2
import Foundation

enum DiffEngine: String, ExpressibleByArgument, CaseIterable {
    case cli
    case libgit2
}

struct Diff: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Produce the full patch between two revisions, with rename detection."
    )

    @OptionGroup var common: CommonOptions

    @Option(help: "How to compute the diff.")
    var engine: DiffEngine = .cli

    @Argument(help: "The older revision.")
    var from: String

    @Argument(help: "The newer revision.")
    var to: String

    func run() throws {
        var report = Report("diff \(from)..\(to), \(engine.rawValue)")
        for _ in 0..<common.runs {
            let counter = PatchCounter()
            switch engine {
            case .cli:
                var splitter = RecordSplitter(separator: 0x0A)
                let status = try streamGit(["diff", "--no-color", "--no-ext-diff", "-M", from, to], in: common.repoPath) { chunk in
                    if counter.firstOutput == nil { counter.firstOutput = counter.timer.total }
                    counter.bytes += chunk.count
                    splitter.feed(chunk) { line in
                        counter.lines += 1
                        if line.starts(with: "diff --git ".utf8) { counter.files += 1 }
                    }
                }
                guard status == 0 else { throw BenchError("git diff exited with status \(status)") }
            case .libgit2:
                try libgit2Diff(counter)
            }
            report.record("first output", counter.firstOutput ?? counter.timer.total)
            report.record("whole patch", counter.timer.total)
            report.note("\(counter.files) files, \(counter.lines) lines, \(counter.bytes / 1_048_576) MB of patch text")
        }
        report.print()
    }

    private func libgit2Diff(_ counter: PatchCounter) throws {
        let repo = try Repository(path: common.repoPath)
        var oldTree: OpaquePointer?
        var newTree: OpaquePointer?
        try check(git_revparse_single(&oldTree, repo.pointer, "\(from)^{tree}"), "resolving \(from)")
        defer { git_object_free(oldTree) }
        try check(git_revparse_single(&newTree, repo.pointer, "\(to)^{tree}"), "resolving \(to)")
        defer { git_object_free(newTree) }

        var options = git_diff_options()
        try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)), "git_diff_options_init")
        var diff: OpaquePointer?
        try check(git_diff_tree_to_tree(&diff, repo.pointer, oldTree, newTree, &options), "git_diff_tree_to_tree")
        defer { git_diff_free(diff) }

        var findOptions = git_diff_find_options()
        try check(git_diff_find_options_init(&findOptions, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION)), "git_diff_find_options_init")
        findOptions.flags = GIT_DIFF_FIND_RENAMES.rawValue
        try check(git_diff_find_similar(diff, &findOptions), "git_diff_find_similar")
        counter.files = git_diff_num_deltas(diff)

        let payload = Unmanaged.passUnretained(counter).toOpaque()
        try check(git_diff_print(diff, GIT_DIFF_FORMAT_PATCH, { _, _, line, payload in
            let counter = Unmanaged<PatchCounter>.fromOpaque(payload!).takeUnretainedValue()
            if counter.firstOutput == nil { counter.firstOutput = counter.timer.total }
            counter.lines += 1
            counter.bytes += line!.pointee.content_len
            return 0
        }, payload), "git_diff_print")
    }
}

final class PatchCounter {
    let timer = LapTimer()
    var firstOutput: Duration?
    var files = 0
    var lines = 0
    var bytes = 0
}
