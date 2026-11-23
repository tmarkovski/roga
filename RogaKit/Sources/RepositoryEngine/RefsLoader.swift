import GitCore
import GitRunner

/// Loads every ref, and the commit `HEAD` points to.
enum RefsLoader {
    /// - Parameter directory: The worktree whose `HEAD` and current branch
    ///   to read, or the git directory for the main worktree's.
    /// - Parameter priority: Lower when nobody is waiting for the refs, as in
    ///   upkeep that runs alongside loading history.
    @concurrent
    static func load(git: Git, in directory: String, priority: GitCommand.Priority = .normal) async throws -> RefList {
        // for-each-ref names every ref and marks the current branch, and
        // show-ref gives HEAD and what annotated tags lead to, without
        // reading any objects. show-ref exits with status 1 when there's
        // nothing to show, as in a repository without commits.
        var list = GitCommand("for-each-ref", "--format=" + RefListParser.format, in: directory)
        list.priority = priority
        var tags = GitCommand(ShowRefParser.arguments, in: directory)
        tags.successStatuses = [0, 1]
        tags.priority = priority
        async let tagOutput = git.run(tags)

        let listed: RefListParser.Result
        do {
            listed = try RefListParser.parse(try await git.run(list).output)
        } catch let error as ParseError {
            throw RepositoryError.unexpectedOutput(list, error.description)
        }
        let shown: ShowRefParser.Result
        do {
            shown = try ShowRefParser.parse(try await tagOutput.output)
        } catch let error as ParseError {
            throw RepositoryError.unexpectedOutput(tags, error.description)
        }

        var refs = listed.refs
        for index in refs.indices {
            if let peeled = shown.peeled[refs[index].name] { refs[index].peeled = peeled }
        }
        // With neither a current branch nor a commit, HEAD names a branch that
        // has no commits yet, which only symbolic-ref can name. It exits with
        // status 1 for a detached HEAD, which needs a commit, so that can't be
        // the case here, but it's safe either way.
        var unbornBranch: String?
        if listed.currentBranch == nil, shown.head == nil {
            var head = GitCommand("symbolic-ref", "--quiet", "HEAD", in: directory)
            head.successStatuses = [0, 1]
            head.priority = priority
            let name = try await git.text(head)
            unbornBranch = name.isEmpty ? nil : name
        }
        return RefList(refs: refs, currentBranch: listed.currentBranch, head: shown.head, unbornBranch: unbornBranch)
    }
}
