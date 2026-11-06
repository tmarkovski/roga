import Foundation
import Synchronization

/// One run of a program other than git, such as an agent's command-line tool:
/// which program, its arguments, the folder it runs in, and how long it may take.
public struct ProgramCommand: Sendable, Hashable, CustomStringConvertible {
    /// The absolute path of the program. Roga never asks a shell to find it.
    public var executable: String
    /// The arguments after the program's name.
    public var arguments: [String]
    /// The absolute path of the folder it runs in, or nil for wherever Roga is.
    public var directory: String?
    /// Variables to set for this run, on top of the ones every program gets.
    public var environment: [String: String] = [:]
    public var priority = GitCommand.Priority.normal
    /// How long it may run before Roga stops it, or nil for as long as it takes.
    public var timeout: Duration?
    /// How much it may print to standard output before Roga stops it.
    public var outputLimit = 1 << 20

    public init(_ executable: String, _ arguments: [String], in directory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
    }

    /// The program's name, as someone would type it with the program in their
    /// `PATH`.
    public var name: String {
        (executable as NSString).lastPathComponent
    }

    /// The command as someone would type it, for logs and error messages, with
    /// the program's full path.
    public var description: String {
        ([executable] + arguments).map(ShellQuoting.quoted).joined(separator: " ")
    }
}

/// How a program ended, and what it printed. Unlike git's commands, a program's
/// exit status is an answer for the caller to read, so a status other than zero
/// isn't an error here.
public struct ProgramResult: Sendable, Hashable {
    public var status: ExitStatus
    /// What it wrote to standard output.
    public var output: [UInt8]
    /// What it wrote to standard error, cut to its last 64 KB.
    public var errorOutput: String
    /// How long it ran.
    public var duration: Duration

    public init(status: ExitStatus, output: [UInt8], errorOutput: String, duration: Duration) {
        self.status = status
        self.output = output
        self.errorOutput = errorOutput
        self.duration = duration
    }

    /// The output decoded as UTF-8.
    public var text: String {
        String(decoding: output, as: UTF8.self)
    }

    /// Whether it exited with status 0.
    public var succeeded: Bool {
        status == .exited(0)
    }
}

public enum ProgramError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The program couldn't be started.
    case couldNotStart(ProgramCommand, SpawnError)
    /// It ran longer than its time limit, so Roga stopped it. This is what it
    /// had printed by then.
    case timedOut(ProgramCommand, Duration, errorOutput: String)
    /// It printed more than its output limit, so Roga stopped it.
    case outputTooLong(ProgramCommand, limit: Int)

    public var description: String {
        switch self {
        case .couldNotStart(_, let error):
            error.description
        case .timedOut(let command, let limit, _):
            "\(command.name) didn't finish within \(limit.formatted(.units(allowed: [.seconds, .minutes], width: .wide))), so Roga stopped it."
        case .outputTooLong(let command, let limit):
            "\(command.name) printed more than \(limit.formatted(.byteCount(style: .memory))), so Roga stopped it."
        }
    }

    public var command: ProgramCommand {
        switch self {
        case .couldNotStart(let command, _), .timedOut(let command, _, _), .outputTooLong(let command, _):
            command
        }
    }
}

/// Runs programs other than git, with the same environment and command log as
/// git's commands, so everything Roga runs is in one place (ARCHITECTURE.md).
public struct Programs: Sendable {
    public let log: CommandLog
    /// The environment every program starts from.
    public let environment: [String: String]

    /// - Parameters:
    ///   - searchPath: The `PATH` the programs get, which is the login shell's,
    ///     the same one git gets.
    ///   - environment: Variables to set for every program, after Roga's own.
    ///   - inheritedEnvironment: The environment to start from, which is Roga's
    ///     own by default.
    public init(
        searchPath: String,
        log: CommandLog = CommandLog(),
        environment: [String: String] = [:],
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.log = log
        var base = Git.environment(inheriting: inheritedEnvironment, searchPath: searchPath)
        // Nobody sees the output in a terminal, so colors would only be noise.
        base["NO_COLOR"] = "1"
        self.environment = base.merging(environment) { $1 }
    }

    /// The programs that the given git's commands share an environment and a
    /// log with.
    public init(sharingWith git: Git) {
        self.init(searchPath: git.installation.searchPath, log: git.log)
    }

    /// Runs a program to the end and returns how it exited and what it printed.
    ///
    /// - Parameter input: Bytes to write to its standard input, which is then
    ///   closed. Without input, standard input is empty.
    /// - Throws: `ProgramError`, or `CancellationError` when the task is
    ///   cancelled, which also stops the program and everything it started.
    @concurrent
    public func run(_ command: ProgramCommand, input: [UInt8]? = nil) async throws -> ProgramResult {
        try Task.checkCancellation()
        let entry = log.begin(program: command.executable, arguments: command.arguments, directory: command.directory)
        let clock = ContinuousClock()
        let started = clock.now
        let process: ChildProcess
        do {
            process = try ChildProcess.spawn(
                executable: command.executable,
                arguments: command.arguments,
                environment: environment.merging(command.environment) { $1 },
                directory: command.directory,
                withInput: input != nil,
                priority: command.priority,
                onExit: { [log] status in log.finish(entry, .finished(status)) }
            )
        } catch {
            log.finish(entry, .couldNotStart(error.description))
            throw ProgramError.couldNotStart(command, error)
        }

        let timedOut = Atomic(false)
        let timer: Task<Void, Never>? = command.timeout.map { limit in
            Task {
                guard (try? await Task.sleep(for: limit)) != nil else { return }
                timedOut.store(true, ordering: .sequentiallyConsistent)
                process.terminate()
                process.output.close()
            }
        }
        defer { timer?.cancel() }

        return try await withTaskCancellationHandler {
            if let input, let writer = process.input {
                // Write while reading, so that neither side waits for the other,
                // and close at once so a program that reads to the end finishes.
                writer.submit(input)
                writer.close()
            }
            var output: [UInt8] = []
            var tooLong = false
            do {
                while let chunk = try await process.output.next() {
                    output.append(contentsOf: chunk)
                    if output.count > command.outputLimit {
                        tooLong = true
                        process.terminate()
                        process.output.close()
                        break
                    }
                }
            } catch {
                // Closing the pipe early, for a time limit or cancellation, ends
                // the read. What that means is decided below.
            }
            let status = await process.exitStatus()
            let errorOutput = String(decoding: await process.errorOutput.collected(), as: UTF8.self)
            try Task.checkCancellation()
            if timedOut.load(ordering: .sequentiallyConsistent), let limit = command.timeout {
                throw ProgramError.timedOut(command, limit, errorOutput: errorOutput)
            }
            if tooLong {
                throw ProgramError.outputTooLong(command, limit: command.outputLimit)
            }
            return ProgramResult(status: status, output: output, errorOutput: errorOutput, duration: clock.now - started)
        } onCancel: {
            process.terminate()
            process.output.close()
        }
    }
}

/// Quoting for commands shown to people, so they can be pasted into a shell.
public enum ShellQuoting {
    public static func quoted(_ argument: String) -> String {
        let plain = !argument.isEmpty && argument.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "-_./=:@%+,^~".unicodeScalars.contains($0)
        }
        if plain { return argument }
        return "'" + argument.replacing("'", with: "'\\''") + "'"
    }
}
