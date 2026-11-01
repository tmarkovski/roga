import ArgumentParser

struct VerifyGraph: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify-graph",
        abstract: "Check the commit-graph reader against `git log --date-order`."
    )

    @OptionGroup var common: CommonOptions

    func run() throws {
        let lines = try runGit(["rev-parse", "--absolute-git-dir", "HEAD"], in: common.repoPath)
            .split(separator: "\n").map(String.init)
        let graph = try CommitGraph(path: lines[0] + "/objects/info/commit-graph")
        guard let head = OID(hex: lines[1]), let headPosition = graph.position(of: head) else {
            throw BenchError("HEAD isn't in the commit-graph")
        }
        let (rows, _) = graph.dateOrder(from: headPosition)

        var expected: [(oid: OID, parents: [OID])] = []
        var splitter = RecordSplitter(separator: 0x0A)
        try streamGit(["log", "--date-order", "--format=%H %P", "HEAD"], in: common.repoPath) { chunk in
            splitter.feed(chunk) { line in
                var oids: [OID] = []
                var offset = 0
                while offset + 40 <= line.count {
                    if let oid = OID(hex: UnsafeBufferPointer(rebasing: line[offset..<offset + 40])) { oids.append(oid) }
                    offset += 41
                }
                expected.append((oids[0], Array(oids.dropFirst())))
            }
        }

        var parentMismatches = 0
        var scratch: [Int32] = []
        for commit in expected {
            guard let position = graph.position(of: commit.oid) else {
                parentMismatches += 1
                continue
            }
            scratch.removeAll(keepingCapacity: true)
            graph.parents(of: position, into: &scratch)
            if scratch.map(graph.oid) != commit.parents { parentMismatches += 1 }
        }
        let samePosition = zip(rows, expected).filter { graph.oid($0) == $1.oid }.count
        let sameSet = Set(rows.map(graph.oid)) == Set(expected.map(\.oid))

        print("git log: \(expected.count) commits; commit-graph order: \(rows.count) commits")
        print("same set of commits: \(sameSet)")
        print("commits whose parents differ from git's: \(parentMismatches)")
        print("rows at the same position as git's order: \(samePosition) of \(expected.count)")
    }
}
