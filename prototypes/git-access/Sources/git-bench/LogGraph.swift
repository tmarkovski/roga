import ArgumentParser
import Clibgit2

enum MetadataSource: String, ExpressibleByArgument, CaseIterable {
    case catFile = "cat-file"
    case libgit2
}

struct LogGraph: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log-graph",
        abstract: "Order history from the commit-graph file and load text only for visible rows."
    )

    @OptionGroup var common: CommonOptions

    @Option(help: "Where to read commit metadata for visible rows.")
    var meta: MetadataSource = .catFile

    func run() throws {
        var report = Report("log-graph, commit-graph order with \(meta.rawValue) metadata")
        for _ in 0..<common.runs {
            var timer = LapTimer()
            let lines = try runGit(["rev-parse", "--absolute-git-dir", "HEAD"], in: common.repoPath)
                .split(separator: "\n").map(String.init)
            guard lines.count == 2, let head = OID(hex: lines[1]) else {
                throw BenchError("Couldn't resolve HEAD")
            }
            report.record("resolve HEAD", timer.lap())

            let graph = try CommitGraph(path: lines[0] + "/objects/info/commit-graph")
            guard let headPosition = graph.position(of: head) else {
                throw BenchError("HEAD isn't in the commit-graph; rewrite it with `git commit-graph write --reachable`")
            }
            report.record("open commit-graph", timer.lap())

            let (rows, rowOf) = graph.dateOrder(from: headPosition)
            report.record("walk and order", timer.lap())

            let reader = try MetadataReader(source: meta, repo: common.repoPath)
            let screen = rows.prefix(common.screenRows).map(graph.oid)
            let firstWindow = try reader.commits(screen)
            report.record("first window of metadata", timer.lap())
            report.record("first screen", timer.total)

            let middle = rows.count / 2
            let jump = rows[middle..<min(rows.count, middle + common.screenRows)].map(graph.oid)
            _ = try reader.commits(jump)
            report.record("jump to the middle", timer.lap())

            var scratch: [Int32] = []
            let layout = layoutGraph(rowCount: rows.count) { row, out in
                scratch.removeAll(keepingCapacity: true)
                graph.parents(of: rows[row], into: &scratch)
                for parent in scratch where rowOf[Int(parent)] >= 0 { out.append(rowOf[Int(parent)]) }
            }
            report.record("layout", timer.lap())
            report.note("\(rows.count) commits of \(graph.count) in the graph, up to \(layout.maxWidth) lanes wide")
            report.note("first row: \(firstWindow.first?.subject ?? "none")")
        }
        report.print()
    }
}

/// Loads metadata for a window of commits from either source.
final class MetadataReader {
    private let catFile: CatFileBatch?
    private let repository: Repository?

    init(source: MetadataSource, repo: String) throws {
        switch source {
        case .catFile:
            catFile = try CatFileBatch(repo: repo)
            repository = nil
        case .libgit2:
            catFile = nil
            repository = try Repository(path: repo)
        }
    }

    func commits(_ oids: [OID]) throws -> [CommitMeta] {
        if let catFile { return try catFile.commits(oids) }
        return try oids.map { oid in
            var raw = (oid.w0.bigEndian, oid.w1.bigEndian, oid.w2.bigEndian)
            var gitOID = git_oid()
            withUnsafeBytes(of: &raw) { _ = git_oid_fromraw(&gitOID, $0.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
            return try repository!.commit(&gitOID).meta
        }
    }
}
