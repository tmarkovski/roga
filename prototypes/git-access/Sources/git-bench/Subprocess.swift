import Foundation

/// The git binary to run: `GIT_BENCH_GIT` if set, otherwise the first `git` on `PATH`.
let gitExecutable: URL = {
    let environment = ProcessInfo.processInfo.environment
    if let explicit = environment["GIT_BENCH_GIT"] { return URL(fileURLWithPath: explicit) }
    for directory in (environment["PATH"] ?? "/usr/bin").split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("git")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return URL(fileURLWithPath: "/usr/bin/git")
}()

/// A git child process started with `posix_spawn`.
///
/// Foundation's `Process.waitUntilExit()` polls a run loop and added 65–70 ms to every git command
/// in this prototype, even after git had exited, so we wait with `waitpid` instead.
final class GitProcess {
    let pid: pid_t
    /// The read end of git's standard output.
    let output: Int32
    /// The write end of git's standard input, when requested.
    let input: Int32?

    init(_ arguments: [String], in repo: String, withInput: Bool = false) throws {
        var outputPipe: [Int32] = [-1, -1]
        var inputPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0, !withInput || pipe(&inputPipe) == 0 else {
            throw BenchError("pipe failed: \(String(cString: strerror(errno)))")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if withInput {
            posix_spawn_file_actions_adddup2(&actions, inputPipe[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        // Close every other descriptor in the child, so git never holds our other pipes open.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = (["git", "-C", repo] + arguments).map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0)=\($1)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, gitExecutable.path, &actions, &attributes, argv, envp)
        close(outputPipe[1])
        if withInput { close(inputPipe[0]) }
        guard result == 0 else {
            close(outputPipe[0])
            if withInput { close(inputPipe[1]) }
            throw BenchError("posix_spawn failed: \(String(cString: strerror(result)))")
        }
        self.pid = pid
        self.output = outputPipe[0]
        self.input = withInput ? inputPipe[1] : nil
    }

    /// Closes our ends of the pipes, waits for git to exit, and returns its exit status.
    func wait() -> Int32 {
        if let input { close(input) }
        close(output)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return status & 0x7F == 0 ? (status >> 8) & 0xFF : -1
    }
}

/// Runs git in `repo` and passes its standard output to `consume` in chunks as they arrive.
@discardableResult
func streamGit(_ arguments: [String], in repo: String, chunkSize: Int = 1 << 20,
               consume: (UnsafeRawBufferPointer) -> Void) throws -> Int32 {
    let process = try GitProcess(arguments, in: repo)
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
    defer { buffer.deallocate() }
    while true {
        let count = read(process.output, buffer, chunkSize)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { break }
        consume(UnsafeRawBufferPointer(start: buffer, count: count))
    }
    return process.wait()
}

/// Runs git in `repo` and returns its standard output as text.
func runGit(_ arguments: [String], in repo: String) throws -> String {
    var bytes: [UInt8] = []
    let status = try streamGit(arguments, in: repo) { bytes.append(contentsOf: $0) }
    guard status == 0 else {
        throw BenchError("git \(arguments.joined(separator: " ")) exited with status \(status)")
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Splits a byte stream into records that end with `separator`, without copying records
/// that arrive whole within one chunk.
struct RecordSplitter {
    let separator: UInt8
    private var pending: [UInt8] = []

    init(separator: UInt8) { self.separator = separator }

    mutating func feed(_ chunk: UnsafeRawBufferPointer, _ body: (UnsafeBufferPointer<UInt8>) -> Void) {
        let bytes = chunk.assumingMemoryBound(to: UInt8.self)
        guard let base = bytes.baseAddress else { return }
        var start = 0
        while start < bytes.count, let hit = memchr(base + start, Int32(separator), bytes.count - start) {
            let end = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
            let piece = UnsafeBufferPointer(start: base + start, count: end - start)
            if pending.isEmpty {
                body(piece)
            } else {
                pending.append(contentsOf: piece)
                pending.withUnsafeBufferPointer(body)
                pending.removeAll(keepingCapacity: true)
            }
            start = end + 1
        }
        if start < bytes.count {
            pending.append(contentsOf: UnsafeBufferPointer(start: base + start, count: bytes.count - start))
        }
    }

    /// Delivers a final record that had no trailing separator.
    mutating func finish(_ body: (UnsafeBufferPointer<UInt8>) -> Void) {
        if !pending.isEmpty { pending.withUnsafeBufferPointer(body) }
        pending.removeAll()
    }
}

/// Walks the fields of one record, separated by a single byte.
struct FieldCursor {
    let buffer: UnsafeBufferPointer<UInt8>
    private var position = 0

    init(_ buffer: UnsafeBufferPointer<UInt8>) { self.buffer = buffer }

    mutating func next(_ separator: UInt8) -> UnsafeBufferPointer<UInt8> {
        let start = position
        while position < buffer.count && buffer[position] != separator { position += 1 }
        let field = UnsafeBufferPointer(rebasing: buffer[start..<position])
        position = min(position + 1, buffer.count)
        return field
    }

    func rest() -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(rebasing: buffer[position...])
    }
}

func parseInt(_ bytes: UnsafeBufferPointer<UInt8>) -> Int64 {
    var value: Int64 = 0
    for byte in bytes where byte >= 0x30 && byte <= 0x39 { value = value * 10 + Int64(byte - 0x30) }
    return value
}
