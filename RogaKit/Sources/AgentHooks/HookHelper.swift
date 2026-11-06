import Darwin
import Foundation

/// The `roga hook` helper inside Roga.app, which every agent hook runs
/// (decision 41).
///
/// Each hook runs `roga hook --host claude|codex --event <name>` with the
/// event's JSON on standard input. The helper keeps the few fields Roga
/// needs, finds the agent's process, sends one `HookEvent` to Roga's socket
/// and exits. It runs on every tool call an agent makes, and the agent waits
/// for it, so it does as little as it can: no retries, a fifth of a second
/// at most to connect and as long again to write, and nothing but reading
/// its input when Roga isn't running. A run takes a few milliseconds.
///
/// Whatever happens it prints nothing and exits with status 0. Claude Code
/// adds a hook's standard output to what the model reads, and both agents
/// show an error for any other status. The one exception is
/// `roga --version`, which no hook runs: it prints which copy of Roga the
/// helper came with.
public enum HookHelper {
    /// Runs the helper with this process's arguments, environment and
    /// standard input, then exits with status 0. It never returns.
    public static func main() -> Never {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if asksForVersion(arguments) {
            print(versionLine(executable: executablePath()))
            exit(0)
        }
        silenceStandardOutput()
        _ = run(arguments: arguments, environment: ProcessInfo.processInfo.environment, input: STDIN_FILENO)
        exit(0)
    }

    /// What a run of the helper did, for tests.
    enum Outcome: Hashable {
        /// The arguments weren't a hook's, or nothing named the event.
        case ignored
        /// Roga's own Generate run started the agent.
        case generating
        /// Roga isn't listening.
        case noSocket
        case sent(HookEvent)
        /// Roga didn't take the event in time.
        case notSent(HookEvent)
    }

    /// Everything `main` does, with what it reads passed in.
    ///
    /// - Parameters:
    ///   - socketPath: Finds the socket, which is only looked for once the
    ///     arguments say this is a hook.
    ///   - parent: Where the walk up to the agent's process starts.
    ///   - now: When the hook ran. It's read first, because the agent ran
    ///     the hook then, and hooks that run close together must keep their
    ///     order.
    static func run(
        arguments: [String],
        environment: [String: String],
        input: Int32,
        socketPath: ([String: String]) -> String = HookHelper.defaultSocketPath(environment:),
        parent: pid_t = getppid(),
        now: Date = Date()
    ) -> Outcome {
        // Roga's own Generate runs set this, so they never show up in the
        // sidebar as an agent at work.
        if environment["ROGA_GENERATING"] == "1" {
            return .generating
        }
        guard let invocation = Invocation(arguments) else {
            drain(input)
            return .ignored
        }
        let path = socketPath(environment)
        guard path.utf8.count <= HookSocket.maximumPathLength, access(path, F_OK) == 0 else {
            drain(input)
            return .noSocket
        }
        let payload = Payload(readInput(from: input))
        guard
            let event = event(
                for: invocation,
                payload: payload,
                process: AgentProcess.find(above: parent),
                time: now.timeIntervalSince1970
            )
        else {
            return .ignored
        }
        return send(event, toSocketAt: path) ? .sent(event) : .notSent(event)
    }

    // MARK: - Arguments

    /// What the hook's command line says.
    struct Invocation: Hashable {
        var host: AgentHost
        /// The event the hook was installed for, used when the payload
        /// doesn't name one.
        var event: String?

        /// Reads `hook --host <agent> --event <name>`. Anything else isn't
        /// a hook, and the helper quietly does nothing.
        init?(_ arguments: [String]) {
            guard arguments.first == "hook" else { return nil }
            var host: AgentHost?
            var event: String?
            var rest = arguments.dropFirst()
            while let option = rest.popFirst() {
                guard let value = rest.popFirst() else { return nil }
                switch option {
                case "--host":
                    guard let named = AgentHost(rawValue: value) else { return nil }
                    host = named
                case "--event":
                    event = value.isEmpty ? nil : value
                default:
                    return nil
                }
            }
            guard let host else { return nil }
            self.host = host
            self.event = event
        }
    }

    // MARK: - Standard input

    /// The hook's input, up to the part the helper keeps.
    struct Input {
        var bytes: [UInt8]
        /// Whether `bytes` is all of it.
        var isWhole: Bool
    }

    /// How much of the input the helper keeps. Claude Code's payloads carry
    /// whole tool results, and GitKraken's helper drops every event over
    /// 1 MiB, which left its sessions stuck on a tool that had finished.
    static let inputKept = 16 << 20

    /// How long the helper waits for more input before it goes on with what
    /// it has, in milliseconds. Both agents write the payload at once and
    /// close the pipe, so this only matters if one ever leaves it open.
    static let inputWait: Int32 = 1000

    /// Reads standard input to the end, keeping the first `limit` bytes and
    /// throwing the rest away. Reading all of it means the agent never finds
    /// the pipe closed while it's still writing.
    static func readInput(from descriptor: Int32, keeping limit: Int = inputKept) -> Input {
        guard isatty(descriptor) == 0 else { return Input(bytes: [], isWhole: true) }
        let chunkSize = 64 * 1024
        let chunk = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 1)
        defer { chunk.deallocate() }
        var kept: [UInt8] = []
        var isWhole = true
        var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while true {
            waiting.revents = 0
            let ready = poll(&waiting, 1, inputWait)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                isWhole = false
                break
            }
            let count = read(descriptor, chunk.baseAddress, chunkSize)
            if count > 0 {
                let room = max(0, limit - kept.count)
                if room > 0 {
                    kept.append(contentsOf: UnsafeRawBufferPointer(rebasing: chunk[..<min(count, room)]))
                }
                if count > room {
                    isWhole = false
                }
            } else if count == 0 {
                break
            } else if errno != EINTR && errno != EAGAIN {
                break
            }
        }
        return Input(bytes: kept, isWhole: isWhole)
    }

    /// Reads standard input to the end and keeps none of it.
    static func drain(_ descriptor: Int32) {
        _ = readInput(from: descriptor, keeping: 0)
    }

    // MARK: - The payload

    /// The fields of a hook's JSON that Roga uses. Prompts and tool output
    /// are never read out of it, and of a tool's input only the few fields
    /// that its line is made from (decision 43).
    struct Payload: Hashable {
        var event: String?
        var session: String?
        var cwd: String?
        /// Where a `CwdChanged` moved to.
        var newCwd: String?
        var tool: String?
        var notification: String?
        var source: String?
        var reason: String?
        var subagent: String?
        var error: String?
        var backgroundTasks: Int?
        /// What the line for the tool is made from.
        var toolInput: ToolInput?
        /// The first line of the agent's last reply, for `Stop`.
        var reply: String?

        /// The longest folder kept, in bytes. Longer fields are dropped
        /// rather than cut, since a cut value would be wrong, and so that
        /// one event stays well inside the socket's 8 KB buffer.
        static let folderLimit = 4096
        /// The longest of any other field kept, in bytes.
        static let fieldLimit = 256
        /// How far into a payload the helper looks for fields when it can't
        /// read it as JSON. Both agents write the common fields first.
        static let scanLimit = 64 * 1024

        init(
            event: String? = nil, session: String? = nil, cwd: String? = nil, newCwd: String? = nil,
            tool: String? = nil, notification: String? = nil, source: String? = nil, reason: String? = nil,
            subagent: String? = nil, error: String? = nil, backgroundTasks: Int? = nil,
            toolInput: ToolInput? = nil, reply: String? = nil
        ) {
            self.event = event
            self.session = session
            self.cwd = cwd
            self.newCwd = newCwd
            self.tool = tool
            self.notification = notification
            self.source = source
            self.reason = reason
            self.subagent = subagent
            self.error = error
            self.backgroundTasks = backgroundTasks
            self.toolInput = toolInput
            self.reply = reply
        }

        /// Reads the payload as JSON. When it isn't, or it was too long to
        /// keep whole, it looks for the common fields in its first part, so
        /// that a huge tool result still says which session and tool it was.
        init(_ input: Input) {
            if input.isWhole,
                let object = try? JSONSerialization.jsonObject(with: Data(input.bytes)) as? [String: Any]
            {
                self.init(object)
            } else {
                self.init(scanning: input.bytes.prefix(Self.scanLimit))
            }
        }

        init(_ object: [String: Any]) {
            func text(_ key: String, limit: Int = Payload.fieldLimit) -> String? {
                Payload.usable(object[key] as? String, limit: limit)
            }
            self.init(
                event: text("hook_event_name"),
                session: text("session_id"),
                cwd: text("cwd", limit: Self.folderLimit),
                newCwd: text("new_cwd", limit: Self.folderLimit),
                tool: text("tool_name"),
                notification: text("notification_type"),
                source: text("source"),
                reason: text("reason"),
                subagent: text("agent_id"),
                error: text("error"),
                backgroundTasks: (object["background_tasks"] as? [Any])?.count ?? (object["background_tasks"] as? Int),
                toolInput: (object["tool_input"] as? [String: Any]).map(ToolInput.init),
                reply: (object["last_assistant_message"] as? String).flatMap(Activity.firstLine(ofReply:))
            )
        }

        /// What can be found in the first part of a payload. A tool's line
        /// can still be made when what it needs comes early, as the path of a
        /// file being written, which comes before its contents. A reply that
        /// doesn't end within that part gives no line.
        init(scanning bytes: ArraySlice<UInt8>) {
            func text(_ key: String, limit: Int = Payload.fieldLimit) -> String? {
                Payload.usable(Payload.firstString(named: key, in: bytes), limit: limit)
            }
            self.init(
                event: text("hook_event_name"),
                session: text("session_id"),
                cwd: text("cwd", limit: Self.folderLimit),
                tool: text("tool_name"),
                subagent: text("agent_id"),
                toolInput: ToolInput(scanning: bytes),
                reply: Payload.firstString(named: "last_assistant_message", in: bytes).flatMap(Activity.firstLine(ofReply:))
            )
        }

        static func usable(_ value: String?, limit: Int) -> String? {
            guard let value, !value.isEmpty, value.utf8.count <= limit else { return nil }
            return value
        }

        /// The string value of the first `"key": "…"` in some JSON text,
        /// wherever it is.
        static func firstString(named key: String, in bytes: ArraySlice<UInt8>) -> String? {
            let needle = Array("\"\(key)\"".utf8)
            guard let found = firstIndex(of: needle, in: bytes) else { return nil }
            var index = found + needle.count
            func skipSpace() {
                while index < bytes.endIndex, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
            }
            skipSpace()
            guard index < bytes.endIndex, bytes[index] == UInt8(ascii: ":") else { return nil }
            index += 1
            skipSpace()
            guard index < bytes.endIndex, bytes[index] == UInt8(ascii: "\"") else { return nil }
            let start = index
            index += 1
            while index < bytes.endIndex, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.endIndex else { return nil }
            // JSON itself decodes the string's escapes.
            let literal = Data(bytes[start...index])
            return (try? JSONSerialization.jsonObject(with: literal, options: .fragmentsAllowed)) as? String
        }

        private static func firstIndex(of needle: [UInt8], in bytes: ArraySlice<UInt8>) -> Int? {
            guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
            var index = bytes.startIndex
            let last = bytes.endIndex - needle.count
            while index <= last {
                if bytes[index] == needle[0], bytes[index..<(index + needle.count)].elementsEqual(needle) {
                    return index
                }
                index += 1
            }
            return nil
        }
    }

    /// The event to send. Fields that only some events have are taken only
    /// from those events: elsewhere, `error` and `reason` are the text of a
    /// tool's failure or a denial, which Roga has no use for.
    ///
    /// The line that says what the agent is doing comes with a tool that's
    /// starting or asks to be allowed, and with `Stop`, from the main agent
    /// only, since a subagent's tools don't change its parent's line.
    static func event(for invocation: Invocation, payload: Payload, process: ProcessEntry?, time: Double) -> HookEvent? {
        guard let name = payload.event ?? invocation.event else { return nil }
        var event = HookEvent(
            host: invocation.host,
            event: name,
            session: payload.session,
            cwd: payload.cwd,
            pid: process?.pid,
            processStart: process?.start,
            tool: payload.tool,
            subagent: payload.subagent,
            time: time
        )
        switch name {
        case "SessionStart": event.source = payload.source
        case "SessionEnd": event.reason = payload.reason
        case "Notification": event.notification = payload.notification
        case "Stop":
            event.backgroundTasks = payload.backgroundTasks
            event.activity = payload.subagent == nil ? payload.reply : nil
        case "PreToolUse", "PermissionRequest":
            if payload.subagent == nil, let tool = payload.tool {
                event.activity = Activity.line(host: invocation.host, tool: tool, input: payload.toolInput ?? ToolInput())
            }
        case "StopFailure": event.error = payload.error
        case "CwdChanged": event.cwd = payload.newCwd ?? payload.cwd
        default: break
        }
        return event
    }

    // MARK: - Sending

    /// How long the helper waits to connect to Roga, and then to write, in
    /// milliseconds. Roga takes connections on a queue of their own, so
    /// one that takes longer means Roga is stuck, and the agent shouldn't
    /// wait for it.
    static let sendWait: Int32 = 200

    /// The event as one line of JSON.
    static func line(for event: HookEvent) -> [UInt8]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var bytes = try? Array(encoder.encode(event)) else { return nil }
        bytes.append(UInt8(ascii: "\n"))
        return bytes
    }

    /// Connects to the socket, writes the event and closes. Returns whether
    /// the whole line was written, and returns at once when nothing listens.
    @discardableResult
    static func send(_ event: HookEvent, toSocketAt path: String, within milliseconds: Int32 = sendWait) -> Bool {
        guard let line = line(for: event) else { return false }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        // If Roga closes its end first, writing should fail, not stop the
        // helper with SIGPIPE and a status the agent would report.
        var on: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: 0, tv_usec: suseconds_t(milliseconds) * 1000)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        guard connect(descriptor, to: path, within: milliseconds) else { return false }
        return writeAll(line, to: descriptor)
    }

    /// Connects without blocking, so a listener that's stuck can't hold the
    /// helper up for longer than `milliseconds`, then makes the socket
    /// blocking again, so that writing waits no longer than `SO_SNDTIMEO`.
    private static func connect(_ descriptor: Int32, to path: String, within milliseconds: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        guard let result = HookSocket.withAddress(of: path, { Darwin.connect(descriptor, $0, $1) }) else {
            return false
        }
        if result != 0 {
            guard errno == EINPROGRESS else { return false }
            var waiting = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard poll(&waiting, 1, milliseconds) == 1 else { return false }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return false }
        }
        return fcntl(descriptor, F_SETFL, flags) == 0
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                write(descriptor, buffer.baseAddress.map { $0 + written }, buffer.count - written)
            }
            if count > 0 {
                written += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    // MARK: - roga --version

    /// Whether the command line is `roga --version`, with nothing else. No
    /// hook runs that, so it's the one time the helper prints something.
    static func asksForVersion(_ arguments: [String]) -> Bool {
        arguments == ["--version"]
    }

    /// What `roga --version` prints: which copy of Roga the helper at
    /// `executable` came with, as in `roga 0.1.0 (1), in /Applications/Roga.app`.
    ///
    /// A development build and a copy for trying things each carry their own
    /// helper, and the launcher in Application Support runs the one inside
    /// whichever copy last took the hooks' socket, so this is how to tell
    /// which one a hook reaches. It finds the app the same way the helper finds its socket.
    /// The version is the app's, from its Info.plist, because the helper is
    /// built and shipped with the app and has no version of its own.
    static func versionLine(executable: String?) -> String {
        guard let executable, let app = app(containing: executable) else {
            return "roga, not inside an app"
        }
        var line = "roga"
        if let version = app.info["CFBundleShortVersionString"] as? String, !version.isEmpty {
            line += " \(version)"
        }
        if let build = app.info["CFBundleVersion"] as? String, !build.isEmpty {
            line += " (\(build))"
        }
        return line + ", in \(app.folder)"
    }

    // MARK: - Finding Roga

    /// The socket of the copy of Roga that the helper belongs to.
    static func defaultSocketPath(environment: [String: String]) -> String {
        let identifier = bundleIdentifier(executable: executablePath(), environment: environment)
        return HookSocket.path(supportFolder: HookSocket.supportFolder(bundleIdentifier: identifier))
    }

    /// The bundle ID of the app the helper is inside, so that a copy of Roga
    /// with its own bundle ID hears from its own helper. A helper that isn't
    /// inside an app, such as one built for testing, takes `ROGA_BUNDLE_ID`
    /// from the environment, or Roga's own ID.
    static func bundleIdentifier(executable: String?, environment: [String: String]) -> String {
        if let executable, let identifier = bundleIdentifier(ofAppContaining: executable) {
            return identifier
        }
        if let identifier = environment["ROGA_BUNDLE_ID"], isUsable(identifier) {
            return identifier
        }
        return HookSocket.defaultBundleIdentifier
    }

    /// Reads the bundle ID of the app that `path` is a helper or the main
    /// executable of, as in `Roga.app/Contents/Helpers/roga`.
    static func bundleIdentifier(ofAppContaining path: String) -> String? {
        guard let identifier = app(containing: path)?.info["CFBundleIdentifier"] as? String, isUsable(identifier) else {
            return nil
        }
        return identifier
    }

    /// The folder of the app that `path` is a helper or the main executable
    /// of, as in `Roga.app/Contents/Helpers/roga`, and what its Info.plist
    /// says. Anything deeper in an app, such as a tool inside Xcode.app,
    /// isn't that app's helper.
    static func app(containing path: String) -> (folder: String, info: [String: Any])? {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 4 else { return nil }
        let contents = components.count - 3
        guard components[contents] == "Contents", components[contents - 1].hasSuffix(".app") else { return nil }
        let infoPath = "/" + (components[...contents] + ["Info.plist"]).joined(separator: "/")
        guard
            let data = FileManager.default.contents(atPath: infoPath),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }
        return ("/" + components[..<contents].joined(separator: "/"), info)
    }

    /// Whether a bundle ID can name a folder in Application Support.
    private static func isUsable(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.utf8.count <= 255 && !identifier.contains("/")
            && !identifier.contains("\0") && identifier != "." && identifier != ".."
    }

    /// The real path of the helper's own executable, with links resolved,
    /// because the launcher in Application Support runs it through one.
    static func executablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        guard let real = realpath(buffer, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    /// Points standard output at /dev/null, so that nothing the helper or a
    /// library it uses might print can reach the agent's model.
    private static func silenceStandardOutput() {
        let null = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard null >= 0 else { return }
        dup2(null, STDOUT_FILENO)
        close(null)
    }
}
