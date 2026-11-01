import ArgumentParser
import Clibgit2

enum StatusEngine: String, ExpressibleByArgument, CaseIterable {
    case cli
    case cliFsmonitor = "cli-fsmonitor"
    case libgit2
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Compute working tree status."
    )

    @OptionGroup var common: CommonOptions

    @Option(help: "How to compute status.")
    var engine: StatusEngine = .cli

    func run() throws {
        var report = Report("status, \(engine.rawValue)")
        let repository = engine == .libgit2 ? try Repository(path: common.repoPath) : nil
        for _ in 0..<common.runs {
            var timer = LapTimer()
            switch engine {
            case .cli, .cliFsmonitor:
                let settings = engine == .cliFsmonitor
                    ? ["-c", "core.fsmonitor=true", "-c", "core.untrackedCache=true"]
                    : []
                var entries = 0
                let status = try streamGit(settings + ["status", "--porcelain=v2", "-z"], in: common.repoPath) { chunk in
                    entries += chunk.reduce(0) { $1 == 0 ? $0 + 1 : $0 }
                }
                guard status == 0 else { throw BenchError("git status exited with status \(status)") }
                report.note("\(entries) entries")
            case .libgit2:
                var options = git_status_options()
                try check(git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION)), "git_status_options_init")
                options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
                options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
                var list: OpaquePointer?
                try check(git_status_list_new(&list, repository!.pointer, &options), "git_status_list_new")
                report.note("\(git_status_list_entrycount(list)) entries")
                git_status_list_free(list)
            }
            report.record("status", timer.lap())
        }
        report.print()
    }
}
