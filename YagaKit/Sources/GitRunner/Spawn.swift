import Darwin
import Dispatch
import Foundation
import Synchronization

/// How a child process ended.
public enum ExitStatus: Sendable, Hashable, CustomStringConvertible {
    /// The process exited with this status.
    case exited(Int32)
    /// A signal stopped the process.
    case signaled(Int32)
    /// Something else collected the process's status first, so yaga doesn't
    /// know how it ended.
    case unknown

    init(waitStatus: Int32) {
        // The WIFEXITED and WTERMSIG macros, which Swift doesn't import.
        let signal = waitStatus & 0x7f
        if signal == 0 {
            self = .exited((waitStatus >> 8) & 0xff)
        } else if signal != 0x7f {
            self = .signaled(signal)
        } else {
            self = .unknown
        }
    }

    public var description: String {
        switch self {
        case .exited(let status): "exited with status \(status)"
        case .signaled(let signal): "stopped by signal \(signal)"
        case .unknown: "ended in an unknown way"
        }
    }
}

/// Why a process couldn't be started.
public struct SpawnError: Error, Sendable, Hashable, CustomStringConvertible {
    public var executable: String
    public var directory: String?
    public var errorNumber: Int32

    public var description: String {
        let reason = String(cString: strerror(errorNumber))
        if errorNumber == ENOENT, let directory, !FileManager.default.fileExists(atPath: directory) {
            return "Couldn't start \(executable) in \(directory), because the folder doesn't exist."
        }
        return "Couldn't start \(executable): \(reason)."
    }
}

/// A child process started with `posix_spawn`, with pipes for its standard
/// output and standard error, and optionally for its standard input.
///
/// Foundation's `Process.waitUntilExit()` polls a run loop and added 65 to
/// 70 ms to every git command in the prototype, so yaga starts processes
/// itself. Nothing here blocks Swift's shared thread pool: the pipes are read
/// with `DispatchIO`, and a dispatch source reports when the process exits,
/// before `waitpid` collects its status on the process's own queue.
///
/// Each child leads a new process group, so stopping it also stops any
/// processes it started, such as a textconv filter.
final class ChildProcess: Sendable {
    let pid: pid_t
    let input: PipeWriter?
    let output: PipeReader
    let errorOutput: PipeCollector

    private let queue: DispatchQueue
    private let state = Mutex(State())

    private struct State {
        var status: ExitStatus?
        var waiters: [CheckedContinuation<ExitStatus, Never>] = []
        var exitSource: (any DispatchSourceProcess)?
        var terminating = false
    }

    /// Starts `executable` with `arguments`, which don't include the program
    /// name. Standard input is an empty pipe end that's closed at once unless
    /// `withInput` is true. `onExit` is called on the process's queue once its
    /// status has been collected, whether or not anyone is waiting for it.
    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        directory: String? = nil,
        withInput: Bool = false,
        onExit: @escaping @Sendable (ExitStatus) -> Void = { _ in }
    ) throws(SpawnError) -> ChildProcess {
        let outputPipe = try makePipe(executable, directory)
        let errorPipe: (read: Int32, write: Int32)
        do {
            errorPipe = try makePipe(executable, directory)
        } catch {
            close(outputPipe.read)
            close(outputPipe.write)
            throw error
        }
        var inputPipe: (read: Int32, write: Int32)?
        if withInput {
            do {
                inputPipe = try makePipe(executable, directory)
            } catch {
                [outputPipe.read, outputPipe.write, errorPipe.read, errorPipe.write].forEach { close($0) }
                throw error
            }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let inputPipe {
            posix_spawn_file_actions_adddup2(&actions, inputPipe.read, STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outputPipe.write, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errorPipe.write, STDERR_FILENO)
        if let directory {
            posix_spawn_file_actions_addchdir(&actions, directory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Close every descriptor the file actions don't set up, so the child
        // never holds yaga's other pipes open. Give the child default signal
        // handling and an empty signal mask, whatever yaga's own are, and make
        // it the leader of a new process group.
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP)
        )

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)

        // The child has its own copies of these ends now.
        close(outputPipe.write)
        close(errorPipe.write)
        if let inputPipe { close(inputPipe.read) }

        guard result == 0 else {
            close(outputPipe.read)
            close(errorPipe.read)
            if let inputPipe { close(inputPipe.write) }
            throw SpawnError(executable: executable, directory: directory, errorNumber: result)
        }

        let queue = DispatchQueue(label: "build.yaga.process.\(pid)")
        return ChildProcess(
            pid: pid,
            queue: queue,
            input: inputPipe.map { PipeWriter(fileDescriptor: $0.write, queue: queue) },
            output: PipeReader(fileDescriptor: outputPipe.read, queue: queue),
            errorOutput: PipeCollector(fileDescriptor: errorPipe.read, queue: queue),
            onExit: onExit
        )
    }

    private init(
        pid: pid_t,
        queue: DispatchQueue,
        input: PipeWriter?,
        output: PipeReader,
        errorOutput: PipeCollector,
        onExit: @escaping @Sendable (ExitStatus) -> Void
    ) {
        self.pid = pid
        self.queue = queue
        self.input = input
        self.output = output
        self.errorOutput = errorOutput

        // The source keeps the process object alive until the child has exited
        // and been reaped, so a child never stays a zombie. If the child exits
        // before the source is registered, libdispatch reports the exit anyway.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [self] in
            reap(onExit: onExit)
        }
        state.withLock { $0.exitSource = source }
        source.activate()
    }

    /// Waits for the process to exit and returns how it ended.
    func exitStatus() async -> ExitStatus {
        await withCheckedContinuation { continuation in
            let status = state.withLock { state -> ExitStatus? in
                if let status = state.status { return status }
                state.waiters.append(continuation)
                return nil
            }
            if let status { continuation.resume(returning: status) }
        }
    }

    /// The status if the process has already exited.
    var currentStatus: ExitStatus? {
        state.withLock { $0.status }
    }

    /// Asks the process and its group to stop with `SIGTERM`, and sends
    /// `SIGKILL` if it's still running after `grace`. Signals are sent on the
    /// process's queue, where it's reaped, so they can never reach another
    /// process that has been given the same ID.
    func terminate(grace: Duration = .seconds(2)) {
        queue.async { [self] in
            let shouldSignal = state.withLock { state in
                guard state.status == nil, !state.terminating else { return false }
                state.terminating = true
                return true
            }
            guard shouldSignal else { return }
            signalGroup(SIGTERM)
            queue.asyncAfter(deadline: .now() + grace.dispatchInterval) { [self] in
                if state.withLock({ $0.status == nil }) {
                    signalGroup(SIGKILL)
                }
            }
        }
    }

    private func signalGroup(_ signal: Int32) {
        if kill(-pid, signal) != 0 {
            kill(pid, signal)
        }
    }

    private func reap(onExit: @Sendable (ExitStatus) -> Void) {
        var waitStatus: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &waitStatus, 0)
        } while result == -1 && errno == EINTR
        let status = result == pid ? ExitStatus(waitStatus: waitStatus) : .unknown

        let (waiters, source) = state.withLock { state in
            state.status = status
            defer {
                state.waiters = []
                state.exitSource = nil
            }
            return (state.waiters, state.exitSource)
        }
        source?.cancel()
        onExit(status)
        for waiter in waiters { waiter.resume(returning: status) }
    }

    private static func makePipe(_ executable: String, _ directory: String?) throws(SpawnError) -> (read: Int32, write: Int32) {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else {
            throw SpawnError(executable: executable, directory: directory, errorNumber: errno)
        }
        // Keep both ends out of processes that other code in yaga starts.
        _ = fcntl(ends[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(ends[1], F_SETFD, FD_CLOEXEC)
        return (ends[0], ends[1])
    }
}

extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
