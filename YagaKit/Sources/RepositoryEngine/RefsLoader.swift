import GitCore
import GitRunner

/// Loads every ref, and the commit `HEAD` points to.
enum RefsLoader {
    /// - Parameter directory: The worktree whose `HEAD` and current branch
    ///   to read, or the git directory for the main worktree's.
    /// - Parameter lowPriority: Whether nobody is waiting for the refs, as in
    ///   upkeep that runs alongside loading history.
    static func load(git: Git, in directory: String, lowPriority: Bool = false) async throws -> RefList {
        // for-each-ref names every ref and marks the current branch, and
        // show-ref gives HEAD and what annotated tags lead to, without
        // reading any objects. show-ref exits with status 1 when there's
        // nothing to show, as in a repository without commits.
        var list = GitCommand("for-each-ref", "--format=" + RefListParser.format, in: directory)
        list.runsAtLowPriority = lowPriority
        var tags = GitCommand(ShowRefParser.arguments, in: directory)
        tags.successStatuses = [0, 1]
        tags.runsAtLowPriority = lowPriority
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
        return RefList(refs: refs, currentBranch: listed.currentBranch, head: shown.head)
    }
}
