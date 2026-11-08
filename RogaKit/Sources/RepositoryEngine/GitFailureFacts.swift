import Foundation
import GitRunner

/// What one read-only command showed about a repository where git refused
/// something (decision 63).
public struct GitFailureFact: Sendable, Hashable {
    /// The command, as someone would type it.
    public var command: String
    /// What it printed, or what went wrong with it, since a command that fails
    /// says something about the repository too.
    public var output: String

    public init(command: String, output: String) {
        self.command = command
        self.output = output
    }
}

extension RepositorySession {
    /// How much of any one command's output goes to the agent.
    static let factLimit = 8_000
    /// How many paths from git's words are looked up.
    static let factPathLimit = 8

    /// What's known about a worktree where git said `said`, for an agent to work out
    /// why. Every command here only reads, with no optional locks, and none of them
    /// can stop the others, because the repository may be broken in the same way
    /// that made git refuse. That's why `git status` leaves submodules out.
    public nonisolated func factsAboutRefusal(said: String, in worktree: String) async -> [GitFailureFact] {
        var facts = [
            await fact(["version"], in: worktree),
            await fact(["rev-parse", "HEAD"], in: worktree),
            await fact(["status", "--porcelain=v1", "--branch", "--ignore-submodules=all"], in: worktree),
            await fact(["config", "--file", ".gitmodules", "--get-regexp", "^submodule\\..*\\.path$"], statuses: [0, 1], in: worktree),
        ]
        for path in Self.pathsNamed(in: said, worktree: worktree) {
            facts.append(await fact(["ls-files", "--stage", "--", path], in: worktree))
            // Without --no-index this says nothing about a path that's in the index.
            facts.append(await fact(["check-ignore", "--verbose", "--no-index", "--", path], statuses: [0, 1], in: worktree))
            facts.append(await fact(["ls-tree", "-r", "--name-only", "HEAD", "--", path], in: worktree))
        }
        return facts
    }

    private nonisolated func fact(_ arguments: [String], statuses: Set<Int32> = [0], in worktree: String) async -> GitFailureFact {
        var command = GitCommand(arguments, in: worktree)
        command.successStatuses = statuses
        let output: String
        do {
            let text = try await git.run(command).text.trimmingCharacters(in: .whitespacesAndNewlines)
            output = text.isEmpty ? "(no output)" : text
        } catch {
            output = "failed: " + ((error as? GitError)?.message ?? String(describing: error))
        }
        return GitFailureFact(command: command.description, output: Self.limited(output))
    }

    private static func limited(_ text: String) -> String {
        guard text.count > factLimit else { return text }
        return text.prefix(factLimit) + "\n… and \((text.count - factLimit).formatted()) more characters"
    }

    /// The paths that git's words seem to name, relative to the worktree. git has
    /// no one way of writing them, so this takes a word with a slash in it, or a
    /// quoted word that looks like a file's name. A wrong guess only costs a
    /// lookup that finds nothing.
    static func pathsNamed(in said: String, worktree: String) -> [String] {
        let opening = CharacterSet(charactersIn: "'\"`(")
        let closing = CharacterSet(charactersIn: "'\"`),:;.")
        var paths: [String] = []
        for word in said.split(whereSeparator: \.isWhitespace) where paths.count < factPathLimit {
            let isQuoted = word.first.map { "'\"`".contains($0) } ?? false
            var path = String(word)
            while let first = path.unicodeScalars.first, opening.contains(first) { path.unicodeScalars.removeFirst() }
            while let last = path.unicodeScalars.last, closing.contains(last) { path.unicodeScalars.removeLast() }
            if path.hasPrefix(worktree + "/") {
                path.removeFirst(worktree.count + 1)
            } else if path.hasPrefix("/") {
                continue
            }
            guard path.contains("/") || (isQuoted && path.contains(".")) else { continue }
            guard !path.isEmpty, !path.hasPrefix("-"), !path.hasPrefix(":"), !path.contains(":") else { continue }
            guard !path.hasPrefix(".git/"), !path.hasPrefix("refs/") else { continue }
            if !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    /// Runs a command that someone pressed Run for, and returns what it printed. It
    /// takes the locks it needs, since it's meant to change things, and an editor
    /// can't open because `true` stands in for one (decision 63).
    public nonisolated func runProposedCommand(_ arguments: [String], in worktree: String) async throws -> String {
        var command = GitCommand(arguments, in: worktree)
        command.takesOptionalLocks = true
        command.environment = ["GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true"]
        let result = try await git.run(command)
        let printed = [result.text, result.errorOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return Self.limited(printed)
    }
}
