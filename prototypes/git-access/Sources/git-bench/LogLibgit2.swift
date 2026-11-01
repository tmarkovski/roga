import ArgumentParser
import Clibgit2

struct LogLibgit2: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log-libgit2",
        abstract: "Load the history of HEAD with a libgit2 revision walk."
    )

    @OptionGroup var common: CommonOptions

    func run() throws {
        var report = Report("log-libgit2, topological and time order")
        for _ in 0..<common.runs {
            var timer = LapTimer()
            let repo = try Repository(path: common.repoPath)
            var walk: OpaquePointer?
            try check(git_revwalk_new(&walk, repo.pointer), "git_revwalk_new")
            defer { git_revwalk_free(walk) }
            git_revwalk_sorting(walk, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue)
            try check(git_revwalk_push_head(walk), "git_revwalk_push_head")

            var table = CommitTable()
            table.reserve(1_500_000)
            var oid = git_oid()
            var firstScreen: Duration?
            var walkReady: Duration?
            while git_revwalk_next(&oid, walk) == 0 {
                if walkReady == nil { walkReady = timer.total }
                let (parents, meta) = try repo.commit(&oid)
                table.append(oid: OID(&oid), parents: parents, meta: meta)
                if firstScreen == nil && table.count == common.screenRows { firstScreen = timer.total }
            }

            report.record("first commit from walk", walkReady ?? timer.total)
            report.record("first screen", firstScreen ?? timer.total)
            report.record("all commits loaded", timer.lap())
            let layout = table.layout()
            report.record("index and layout", timer.lap())
            report.note("\(table.count) commits, graph up to \(layout.maxWidth) lanes wide")
        }
        report.print()
    }
}
