import Darwin
import Dispatch
import Foundation
import Synchronization

/// Why Roga couldn't listen for hooks.
public enum HookListenerError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Another copy of Roga with the same bundle ID is already listening.
    case inUse(String)
    /// The socket's path doesn't fit in a socket address.
    case pathTooLong(String)
    /// A system call failed.
    case system(String, path: String, errorNumber: Int32)

    public var description: String {
        switch self {
        case .inUse(let path):
            "Another copy of Roga is already listening for agents' hooks at \(path)."
        case .pathTooLong(let path):
            "Roga can't listen for agents' hooks at \(path), because the path is longer than a socket's can be."
        case .system(let call, let path, let errorNumber):
            "Roga can't listen for agents' hooks at \(path), because \(call) failed: \(String(cString: strerror(errorNumber)))."
        }
    }
}

/// Listens on Roga's socket for the events the helper sends (decision 41).
///
/// Everything happens on a queue of the listener's own, with dispatch
/// sources for the socket and for each connection, so nothing blocks a
/// thread and the helper never waits for Roga. Each connection is a helper
/// that writes one line and closes, and the listener decodes each line it
/// reads into a `HookEvent`.
public final class HookListener: Sendable {
    /// The events, in the order their lines arrive. It keeps every event
    /// until it's read, and ends when the listener stops. A stream has one
    /// reader, so the app reads it in one place.
    public let events: AsyncStream<HookEvent>
    /// Where the listener's socket is.
    public let socketPath: String

    private let continuation: AsyncStream<HookEvent>.Continuation
    private let queue = DispatchQueue(label: "sh.roga.hooks", qos: .userInitiated)
    private let state: Mutex<State>
    /// The socket file's device and inode, so that stopping never removes a
    /// socket that another listener has put in its place.
    private let socketDevice: dev_t
    private let socketInode: ino_t

    /// The longest line a connection may send. The helper's are well under
    /// 8 KB.
    static let lineLimit = 64 * 1024
    /// How many connections can be open at once. Each helper's lasts a few
    /// milliseconds, and helpers beyond this many wait in the socket's
    /// backlog until one closes.
    static let connectionLimit = 64
    /// How long a connection may stay open.
    static let connectionTime: DispatchTimeInterval = .seconds(5)

    private struct State {
        var lock: Int32
        var accepting: (any DispatchSourceRead)?
        /// Whether accepting is suspended, because Roga ran out of file
        /// descriptors or already holds `connectionLimit` connections. With
        /// helpers waiting, the source would otherwise call its handler
        /// without end.
        var acceptingSuspended = false
        var connections: [Int32: Connection] = [:]
        var nextConnection: UInt64 = 0
        var stopped = false

        /// Suspends accepting, and says whether it did.
        mutating func suspendAccepting() -> Bool {
            guard !stopped, !acceptingSuspended, let accepting else { return false }
            accepting.suspend()
            acceptingSuspended = true
            return true
        }

        /// Resumes accepting if it's suspended. Stopping needs this too,
        /// because a suspended source can't be cancelled or released.
        mutating func resumeAccepting() {
            guard acceptingSuspended, let accepting else { return }
            accepting.resume()
            acceptingSuspended = false
        }
    }

    private struct Connection {
        var id: UInt64
        var source: any DispatchSourceRead
        var buffer: [UInt8] = []
    }

    /// Starts listening on `<support folder>/hooks.sock`.
    ///
    /// It first takes an exclusive lock on `hooks.lock` beside the socket, so
    /// that a second copy of Roga with the same bundle ID, such as a Debug
    /// build next to the release, can't take the socket from the first, and
    /// throws `inUse` when the lock is held. Holding the lock means any
    /// socket file already there is left from a copy that quit, so it's
    /// removed. A folder it creates is for the user alone, and the socket
    /// can only be opened by the user, which the listener checks again for
    /// each connection.
    public init(supportFolder: URL) throws {
        let path = HookSocket.path(supportFolder: supportFolder)
        guard path.utf8.count <= HookSocket.maximumPathLength else {
            throw HookListenerError.pathTooLong(path)
        }
        try Self.makeFolder(supportFolder)

        let lockPath = HookSocket.lockPath(supportFolder: supportFolder)
        let lock = Darwin.open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else {
            throw HookListenerError.system("open", path: lockPath, errorNumber: errno)
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            Darwin.close(lock)
            throw error == EWOULDBLOCK
                ? HookListenerError.inUse(path) : .system("flock", path: lockPath, errorNumber: error)
        }

        let socket: BoundSocket
        do {
            socket = try Self.bind(path)
        } catch {
            Darwin.close(lock)
            throw error
        }

        (events, continuation) = AsyncStream.makeStream(of: HookEvent.self)
        socketPath = path
        socketDevice = socket.device
        socketInode = socket.inode
        state = Mutex(State(lock: lock))

        let listening = socket.descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: listening, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnections(on: listening)
        }
        source.setCancelHandler {
            Darwin.close(listening)
        }
        state.withLock { $0.accepting = source }
        source.activate()
    }

    deinit {
        stop()
    }

    /// Stops listening: closes the socket and every open connection, removes
    /// the socket file, lets go of the lock and ends `events`.
    public func stop() {
        let taken = state.withLock { state -> (sources: [any DispatchSourceRead], lock: Int32)? in
            guard !state.stopped else { return nil }
            state.stopped = true
            var sources = state.connections.values.map(\.source)
            // Once it's resumed, the source can call its handler again before
            // it's cancelled, and the handler accepts nothing once stopped.
            state.resumeAccepting()
            if let accepting = state.accepting {
                sources.append(accepting)
            }
            state.accepting = nil
            state.connections = [:]
            return (sources, state.lock)
        }
        guard let taken else { return }
        for source in taken.sources {
            source.cancel()
        }
        // Remove the socket while still holding the lock, so that a listener
        // that takes over next never has its own socket removed.
        var info = stat()
        if lstat(socketPath, &info) == 0, info.st_dev == socketDevice, info.st_ino == socketInode {
            unlink(socketPath)
        }
        Darwin.close(taken.lock)
        continuation.finish()
    }

    // MARK: - The socket

    /// Makes the support folder if it isn't there, for the user alone. A
    /// folder that's already there is left as it is.
    private static func makeFolder(_ folder: URL) throws {
        let path = folder.path(percentEncoded: false)
        var info = stat()
        guard stat(path, &info) != 0 else { return }
        let parent = folder.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            let code = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code
            throw HookListenerError.system("mkdir", path: parent.path(percentEncoded: false), errorNumber: Int32(code ?? Int(EACCES)))
        }
        guard mkdir(path, 0o700) == 0 || errno == EEXIST else {
            throw HookListenerError.system("mkdir", path: path, errorNumber: errno)
        }
    }

    private struct BoundSocket {
        var descriptor: Int32
        var device: dev_t
        var inode: ino_t
    }

    /// Makes the listening socket at `path`, replacing any socket file left
    /// there.
    private static func bind(_ path: String) throws -> BoundSocket {
        func failure(_ call: String, _ error: Int32 = errno) -> HookListenerError {
            .system(call, path: path, errorNumber: error)
        }
        if unlink(path) != 0 && errno != ENOENT {
            throw failure("unlink")
        }
        let listening = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listening >= 0 else { throw failure("socket") }
        var bound = false
        do {
            guard fcntl(listening, F_SETFD, FD_CLOEXEC) == 0 else { throw failure("fcntl") }
            let flags = fcntl(listening, F_GETFL)
            guard flags >= 0, fcntl(listening, F_SETFL, flags | O_NONBLOCK) == 0 else { throw failure("fcntl") }
            guard let result = HookSocket.withAddress(of: path, { Darwin.bind(listening, $0, $1) }) else {
                throw HookListenerError.pathTooLong(path)
            }
            guard result == 0 else { throw failure("bind") }
            bound = true
            // Nobody can connect until `listen`, so the socket is never open
            // to anyone else, even for a moment.
            guard chmod(path, 0o600) == 0 else { throw failure("chmod") }
            var info = stat()
            guard lstat(path, &info) == 0 else { throw failure("lstat") }
            guard listen(listening, SOMAXCONN) == 0 else { throw failure("listen") }
            return BoundSocket(descriptor: listening, device: info.st_dev, inode: info.st_ino)
        } catch {
            Darwin.close(listening)
            if bound { unlink(path) }
            throw error
        }
    }

    // MARK: - Connections

    private func acceptConnections(on listening: Int32) {
        while hasRoom() {
            let descriptor = accept(listening, nil, nil)
            guard descriptor >= 0 else {
                switch errno {
                case EINTR, ECONNABORTED: continue
                case EMFILE, ENFILE: suspendAccepting()
                default: break
                }
                return
            }
            guard Self.configure(descriptor) else {
                Darwin.close(descriptor)
                continue
            }
            openConnection(descriptor)
        }
    }

    /// Whether the listener can take another connection. When it already
    /// holds `connectionLimit`, it suspends accepting until one of them
    /// closes. That leaves the helpers still waiting in the socket's backlog,
    /// with their lines in its buffers, instead of accepting them only to
    /// close them and lose their events.
    private func hasRoom() -> Bool {
        state.withLock { state in
            guard !state.stopped else { return false }
            guard state.connections.count >= Self.connectionLimit else { return true }
            _ = state.suspendAccepting()
            return false
        }
    }

    /// Checks that whoever is at the other end runs as the same user as
    /// Roga, and makes the connection non-blocking.
    private static func configure(_ descriptor: Int32) -> Bool {
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(descriptor, &user, &group) == 0, user == geteuid() else { return false }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { return false }
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    /// Starts reading a connection that `accept` returned.
    ///
    /// libdispatch stops the app when a source is released without ever
    /// having been activated, so nothing here lets that happen. The checks
    /// that can turn a connection away run before its source exists, and
    /// then the source is activated before anything else can see it. Its
    /// handler runs on this same queue, so it can't run before the
    /// connection is in `connections`. If `stop()` ran in between, the
    /// source is cancelled, and its cancel handler closes the descriptor.
    private func openConnection(_ descriptor: Int32) {
        let id = state.withLock { state -> UInt64? in
            guard !state.stopped, state.connections.count < Self.connectionLimit else { return nil }
            state.nextConnection += 1
            return state.nextConnection
        }
        guard let id else {
            Darwin.close(descriptor)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readConnection(descriptor)
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        source.activate()
        let kept = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.connections[descriptor] = Connection(id: id, source: source)
            return true
        }
        guard kept else {
            source.cancel()
            return
        }
        queue.asyncAfter(deadline: .now() + Self.connectionTime) { [weak self] in
            self?.closeConnection(descriptor, id: id)
        }
    }

    /// Reads what has arrived on a connection, and yields each whole line
    /// that decodes as an event. A line that isn't an event is skipped, and
    /// a connection that sends a line longer than `lineLimit` is closed.
    private func readConnection(_ descriptor: Int32) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var lines: [[UInt8]] = []
        var finished = false
        reading: while !finished {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                let received = state.withLock { state -> (lines: [[UInt8]], tooLong: Bool)? in
                    guard var connection = state.connections.removeValue(forKey: descriptor) else { return nil }
                    connection.buffer.append(contentsOf: chunk[..<count])
                    var lines: [[UInt8]] = []
                    var start = 0
                    var tooLong = false
                    while let end = connection.buffer[start...].firstIndex(of: UInt8(ascii: "\n")) {
                        tooLong = tooLong || end - start > Self.lineLimit
                        lines.append(Array(connection.buffer[start..<end]))
                        start = end + 1
                    }
                    connection.buffer.removeFirst(start)
                    tooLong = tooLong || connection.buffer.count > Self.lineLimit
                    state.connections[descriptor] = connection
                    return (lines, tooLong)
                }
                guard let received, !received.tooLong else {
                    lines = []
                    finished = true
                    break reading
                }
                lines += received.lines
            } else if count == 0 {
                // The helper closed its end. A last line without its newline
                // still counts.
                let rest = state.withLock { $0.connections[descriptor]?.buffer ?? [] }
                if !rest.isEmpty { lines.append(rest) }
                finished = true
            } else {
                switch errno {
                case EINTR: continue reading
                case EAGAIN: break reading
                default: finished = true
                }
            }
        }
        for line in lines where !line.isEmpty {
            if let event = try? JSONDecoder().decode(HookEvent.self, from: Data(line)) {
                continuation.yield(event)
            }
        }
        if finished {
            closeConnection(descriptor, id: nil)
        }
    }

    /// Closes a connection. With an ID, only if it's still that connection,
    /// since a descriptor's number is reused once it's closed.
    private func closeConnection(_ descriptor: Int32, id: UInt64?) {
        let source = state.withLock { state -> (any DispatchSourceRead)? in
            guard let connection = state.connections[descriptor], id == nil || connection.id == id else { return nil }
            state.connections[descriptor] = nil
            // There's room for a helper that's waiting, and a descriptor
            // free for it.
            state.resumeAccepting()
            return connection.source
        }
        // The source's cancel handler closes the descriptor, once the source
        // has stopped watching it.
        source?.cancel()
    }

    /// Suspends accepting for a moment, when Roga has run out of file
    /// descriptors.
    private func suspendAccepting() {
        guard state.withLock({ $0.suspendAccepting() }) else { return }
        queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            self?.state.withLock { $0.resumeAccepting() }
        }
    }

    /// How many connections are open, for tests.
    var openConnections: Int {
        state.withLock { $0.connections.count }
    }
}
