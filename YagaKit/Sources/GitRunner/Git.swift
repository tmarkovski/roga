import Foundation

/// Runs git commands with one git installation, and records each one in a
/// command log. Every git command yaga runs goes through here.
public struct Git: Sendable {
    public let installation: GitInstallation
    public let log: CommandLog

    /// The environment every command starts from.
    let environment: [String: String]

    /// Variables that tell git which repository to use. git clears these
    /// itself before it runs a command in another repository, and yaga clears
    /// them so that a variable inherited from wherever yaga was started, such
    /// as a git hook, can't point every command at the wrong repository. This
    /// is the list that `git rev-parse --local-env-vars` prints.
    static let repositoryVariables = [
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
        "GIT_OBJECT_DIRECTORY", "GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
        "GIT_INDEX_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_PREFIX",
        "GIT_SHALLOW_FILE", "GIT_COMMON_DIR",
    ]

    /// - Parameters:
    ///   - environment: Variables to set for every command, after yaga's own.
    ///     Tests use it to keep the user's configuration out.
    ///   - inheritedEnvironment: The environment to start from, which is
    ///     yaga's own by default.
    public init(
        installation: GitInstallation,
        log: CommandLog = CommandLog(),
        environment: [String: String] = [:],
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.installation = installation
        self.log = log
        self.environment = Self.environment(inheriting: inheritedEnvironment, searchPath: installation.searchPath)
            .merging(environment) { $1 }
    }

    /// The environment for git: the inherited one without the variables that
    /// choose a repository, with the `PATH` git should search for the programs
    /// it runs, and with prompts for credentials turned off, because nobody
    /// would see them.
    static func environment(inheriting inherited: [String: String], searchPath: String) -> [String: String] {
        var environment = inherited
        for name in repositoryVariables {
            environment[name] = nil
        }
        environment["PATH"] = searchPath
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment
    }

    /// Runs a command to the end and returns what it printed.
    ///
    /// - Parameter input: Bytes to write to the command's standard input,
    ///   which is empty otherwise.
    /// - Throws: `GitError.failed` when git's exit status isn't one of the
    ///   command's success statuses, `GitError.couldNotStart`, or
    ///   `CancellationError` when the task is cancelled, which also stops git.
    public func run(_ command: GitCommand, input: [UInt8]? = nil) async throws -> GitResult {
        try Task.checkCancellation()
        let running = try start(command, withInput: input != nil)
        return try await withTaskCancellationHandler {
            if let input, let writer = running.process.input {
                // Write while reading, so that neither side waits for the other.
                writer.submit(input)
                writer.close()
            }
            var output: [UInt8] = []
            while let chunk = try await running.process.output.next() {
                if output.isEmpty {
                    output = chunk
                } else {
                    output.append(contentsOf: chunk)
                }
            }
            return try await running.finish(output: output)
        } onCancel: {
            running.stop()
        }
    }

    /// Runs a command and returns its output as text, with the final newline
    /// removed.
    public func text(_ command: GitCommand) async throws -> String {
        var text = try await run(command).text
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// Returns the output of a command as it arrives. Each iteration runs the
    /// command again.
    public func stream(_ command: GitCommand) -> GitOutput {
        GitOutput(git: self, command: command)
    }

    /// Starts git and records the command in the log.
    func start(_ command: GitCommand, withInput: Bool = false) throws(GitError) -> RunningGit {
        let entry = log.begin(command)
        do {
            let process = try ChildProcess.spawn(
                executable: installation.executable,
                arguments: command.fullArguments,
                environment: environment.merging(command.environment) { $1 },
                directory: command.directory,
                withInput: withInput,
                onExit: { [log] status in log.finish(entry, .finished(status)) }
            )
            return RunningGit(command: command, process: process)
        } catch {
            log.finish(entry, .couldNotStart(error.description))
            throw .couldNotStart(command, error)
        }
    }
}

/// What a command printed, and how it exited.
public struct GitResult: Sendable, Hashable {
    /// The exit status, which is one of the command's success statuses.
    public var status: Int32
    /// What git wrote to standard output.
    public var output: [UInt8]
    /// What git wrote to standard error, which is often empty, and is cut to
    /// its last 64 KB.
    public var errorOutput: String

    /// The output decoded as UTF-8.
    public var text: String {
        String(decoding: output, as: UTF8.self)
    }
}

public enum GitError: Error, Sendable, Hashable, CustomStringConvertible {
    /// git couldn't be started.
    case couldNotStart(GitCommand, SpawnError)
    /// git exited with a status the command doesn't count as success, or a
    /// signal stopped it.
    case failed(GitCommand, ExitStatus, errorOutput: String)
    /// A request to `git cat-file` named an object in a way it can't read,
    /// such as with a line break.
    case invalidObjectName(String)
    /// `git cat-file` replied with something yaga didn't expect.
    case unexpectedReply(GitCommand, String)
    /// The `git cat-file` session was closed, or git exited normally.
    case sessionClosed(GitCommand)

    public var description: String {
        switch self {
        case .couldNotStart(_, let error):
            return error.description
        case .failed(let command, let status, let errorOutput):
            let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(command) \(status)" + (message.isEmpty ? "." : ": \(message)")
        case .invalidObjectName(let name):
            return "git cat-file can't read an object named \(name.debugDescription)."
        case .unexpectedReply(let command, let reply):
            return "\(command) replied with \(reply.debugDescription), which yaga didn't expect."
        case .sessionClosed(let command):
            return "\(command) has already exited."
        }
    }
}

/// A git process that's been started for a command.
struct RunningGit: Sendable {
    let command: GitCommand
    let process: ChildProcess

    /// Stops git and stops reading its output.
    func stop() {
        process.terminate()
        process.output.close()
    }

    /// Waits for git to exit and checks its status. Call this once the output
    /// has been read to the end.
    func finish(output: [UInt8] = []) async throws -> GitResult {
        let status = await process.exitStatus()
        let errorOutput = String(decoding: await process.errorOutput.collected(), as: UTF8.self)
        if case .exited(let code) = status, command.successStatuses.contains(code) {
            return GitResult(status: code, output: output, errorOutput: errorOutput)
        }
        try Task.checkCancellation()
        throw GitError.failed(command, status, errorOutput: errorOutput)
    }
}
