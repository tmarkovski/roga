import Clibgit2

func check(_ code: Int32, _ what: @autoclosure () -> String) throws {
    guard code >= 0 else {
        let message = git_error_last().map { String(cString: $0.pointee.message) } ?? "error \(code)"
        throw BenchError("\(what()) failed: \(message)")
    }
}

final class Repository {
    let pointer: OpaquePointer

    init(path: String) throws {
        git_libgit2_init()
        var repo: OpaquePointer?
        try check(git_repository_open(&repo, path), "git_repository_open")
        pointer = repo!
    }

    deinit {
        git_repository_free(pointer)
        git_libgit2_shutdown()
    }

    /// Looks up a commit and returns its parents and metadata.
    func commit(_ oid: UnsafePointer<git_oid>) throws -> (parents: [OID], meta: CommitMeta) {
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, pointer, oid), "git_commit_lookup")
        defer { git_commit_free(commit) }

        var parents: [OID] = []
        let parentCount = git_commit_parentcount(commit)
        parents.reserveCapacity(Int(parentCount))
        for i in 0..<parentCount {
            parents.append(OID(git_commit_parent_id(commit, i)!))
        }
        let author = git_commit_author(commit)!.pointee
        let meta = CommitMeta(
            author: String(cString: author.name),
            email: String(cString: author.email),
            time: author.when.time,
            subject: String(cString: git_commit_summary(commit))
        )
        return (parents, meta)
    }
}

extension OID {
    init(_ oid: UnsafePointer<git_oid>) {
        self = withUnsafeBytes(of: oid.pointee.id) { OID(raw: $0.baseAddress!) }
    }
}
