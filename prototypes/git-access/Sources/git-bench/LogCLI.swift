import ArgumentParser
import Foundation

enum LogOrder: String, ExpressibleByArgument, CaseIterable {
    case `default`, date, topo

    var flags: [String] {
        switch self {
        case .default: []
        case .date: ["--date-order"]
        case .topo: ["--topo-order"]
        }
    }
}

struct LogCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log-cli",
        abstract: "Load the history of HEAD by streaming `git log` output."
    )

    @OptionGroup var common: CommonOptions

    @Option(help: "Commit order to ask git for.")
    var order: LogOrder = .date

    func run() throws {
        var report = Report("log-cli, \(order.rawValue) order")
        for _ in 0..<common.runs {
            var timer = LapTimer()
            var table = CommitTable()
            table.reserve(1_500_000)
            var splitter = RecordSplitter(separator: 0)
            var firstScreen: Duration?
            let screenRows = common.screenRows
            let arguments = ["log", "-z", "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s"] + order.flags + ["HEAD"]

            let status = try streamGit(arguments, in: common.repoPath) { chunk in
                splitter.feed(chunk) { record in
                    table.appendLogRecord(record)
                    if firstScreen == nil && table.count == screenRows { firstScreen = timer.total }
                }
            }
            splitter.finish { table.appendLogRecord($0) }
            guard status == 0 else { throw BenchError("git log exited with status \(status)") }

            report.record("first screen", firstScreen ?? timer.total)
            report.record("all commits loaded", timer.lap())
            let layout = table.layout()
            report.record("index and layout", timer.lap())
            report.note("\(table.count) commits, graph up to \(layout.maxWidth) lanes wide")
        }
        report.print()
    }
}
