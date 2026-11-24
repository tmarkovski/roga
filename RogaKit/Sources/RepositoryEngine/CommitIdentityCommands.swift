import Foundation
import GitCore
import GitRunner

/// Reads who a repository's commits go out as, and changes it, with `git
/// config` alone (decision 103). Roga keeps no profiles, so the command line
/// and Roga always agree.
public enum CommitIdentityCommands {
    /// Where a change is written: the repository's own config, which is
    /// shared by all its worktrees, or the user's global config, which every
    /// repository that doesn't set its own reads.
    public enum Place: Sendable, Hashable {
        case repository
        case everyRepository

        var option: String {
            switch self {
            case .repository: "--local"
            case .everyRepository: "--global"
            }
        }
    }

    /// The settings the identity popover changes, by their keys.
    public enum Key: String, Sendable, Hashable, CaseIterable {
        case name = "user.name"
        case email = "user.email"
        case signsCommits = "commit.gpgsign"
        case signingFormat = "gpg.format"
        case signingKey = "user.signingkey"
    }

    /// One change to a setting, in one place.
    public struct Change: Sendable, Hashable {
        public enum Action: Sendable, Hashable {
            case set(String)
            /// Removes the setting from its place, which lets whatever comes
            /// before it count, such as the global value once the
            /// repository's own is gone.
            case unset
        }

        public var key: Key
        public var action: Action
        public var place: Place

        public static func set(_ key: Key, _ value: String, in place: Place) -> Change {
            Change(key: key, action: .set(value), place: place)
        }

        public static func unset(_ key: Key, in place: Place) -> Change {
            Change(key: key, action: .unset, place: place)
        }

        /// What it runs, by its arguments after `git`.
        public var arguments: [String] {
            switch action {
            case .set(let value): ["config", place.option, key.rawValue, value]
            case .unset: ["config", place.option, "--unset", key.rawValue]
            }
        }
    }

    /// Reads the identity of the repository in `directory`, which takes about
    /// 10 milliseconds, nearly all of it starting git.
    static func read(git: Git, in directory: String) async throws -> CommitIdentity {
        var command = GitCommand(CommitIdentityParser.arguments, in: directory)
        command.successStatuses = [0, 1]
        let output = try await git.run(command).output
        do {
            return try CommitIdentityParser.parse(output)
        } catch {
            throw RepositoryError.unexpectedOutput(command, error.description)
        }
    }

    /// Reads the identity that a repository gets when it sets nothing of its
    /// own: the system's and the user's global config, with what they include
    /// for every repository. git reads it outside any repository, from `/`,
    /// so that a rule such as `includeIf "gitdir:~/work/"` doesn't apply.
    public static func readDefault(git: Git) async throws -> CommitIdentity {
        try await read(git: git, in: "/")
    }

    /// Writes changes to the user's global config, outside any repository,
    /// as Settings does. Each change's place should be `.everyRepository`.
    ///
    /// - Throws: `GitError` when git refuses, which says why.
    public static func writeGlobal(_ changes: [Change], git: Git) async throws {
        try await write(changes, git: git, directory: "/")
    }

    /// Writes each change, in order, stopping at the first one git refuses.
    /// A change that unsets what isn't set does nothing, rather than failing.
    ///
    /// - Throws: `GitError` when git refuses, which says why.
    static func write(_ changes: [Change], git: Git, directory: String) async throws {
        for change in changes {
            var command = GitCommand(change.arguments, in: directory)
            if change.action == .unset {
                // git exits with 5 when the setting isn't there to remove.
                command.successStatuses = [0, 5]
            }
            _ = try await git.run(command)
        }
    }
}

extension RepositorySession {
    /// Who the repository's commits go out as, read in the git directory that
    /// every worktree shares (decision 103).
    @concurrent
    public nonisolated func identity() async throws -> CommitIdentity {
        try await CommitIdentityCommands.read(git: git, in: location.commonDirectory)
    }

    /// Checks a commit's signature with gpg or ssh-keygen, as git's config
    /// says to (decision 104). It takes from a few milliseconds to a second,
    /// so only the commit the panels show is checked.
    ///
    /// - Throws: `GitError` when git can't read the commit.
    @concurrent
    public nonisolated func checkSignature(of commit: ObjectID) async throws -> SignatureCheck {
        let command = GitCommand(SignatureCheckParser.arguments(commit), in: location.commonDirectory)
        let output = try await git.run(command).output
        do {
            return try SignatureCheckParser.parse(output)
        } catch {
            throw RepositoryError.unexpectedOutput(command, error.description)
        }
    }

    /// Changes who the repository's commits go out as, in its own config or
    /// in the user's global config, in order.
    ///
    /// - Throws: `GitError` when git refuses, which says why.
    @concurrent
    public nonisolated func changeIdentity(_ changes: [CommitIdentityCommands.Change]) async throws {
        try await CommitIdentityCommands.write(changes, git: git, directory: location.commonDirectory)
    }
}
