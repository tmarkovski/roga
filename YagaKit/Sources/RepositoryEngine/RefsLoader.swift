import GitCore
import GitRunner

/// Loads every ref with `git for-each-ref`, and the commit `HEAD` points to.
enum RefsLoader {
    static func load(git: Git, location: RepositoryLocation) async throws -> RefList {
        let list = GitCommand("for-each-ref", "--format=" + RefListParser.format, in: location.directory)
        // git marks the current branch in the list, but a detached HEAD needs
        // asking about. A repository without commits has nothing for it to
        // point to, and git exits with status 1.
        var head = GitCommand("rev-parse", "--verify", "--quiet", "HEAD^{commit}", in: location.directory)
        head.successStatuses = [0, 1]
        async let headText = git.text(head)

        let output = try await git.run(list).output
        let parsed: RefListParser.Result
        do {
            parsed = try RefListParser.parse(output)
        } catch {
            throw RepositoryError.unexpectedOutput(list, error.description)
        }
        return RefList(refs: parsed.refs, currentBranch: parsed.currentBranch, head: ObjectID(hex: try await headText))
    }
}
