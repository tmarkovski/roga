import Darwin
import Foundation
import Testing
@testable import AgentHooks

// Payloads shaped like the ones Claude Code 2.1 and Codex 0.166 write, with
// the fields their documentation and generated schemas list.

private let claudePreToolUse = #"""
    {"session_id":"76027137-d5e5-4825-af08-3adb4f0fbc31","transcript_path":"/Users/me/.claude/projects/-Users-me-w/76027137.jsonl","cwd":"/Users/me/w","permission_mode":"default","hook_event_name":"PreToolUse","prompt_id":"p-1","effort":{"level":"high"},"tool_name":"Bash","tool_input":{"command":"cat secret.txt","description":"Show the secret"},"tool_use_id":"toolu_01"}
    """#

private let claudePrompt = #"""
    {"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/Users/me/w","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"my secret plan","session_title":"Secret"}
    """#

private func invocation(_ host: AgentHost, _ event: String? = nil) throws -> HookHelper.Invocation {
    try #require(HookHelper.Invocation(["hook", "--host", host.rawValue] + (event.map { ["--event", $0] } ?? [])))
}

/// The event the helper makes of a payload, without a process.
private func parsed(_ json: String, host: AgentHost = .claude, event: String? = nil) throws -> HookEvent? {
    let payload = HookHelper.Payload(HookHelper.Input(bytes: Array(json.utf8), isWhole: true))
    return HookHelper.event(for: try invocation(host, event), payload: payload, process: nil, time: 1)
}

@Suite(.timeLimit(.minutes(1)))
struct HookHelperTests {
    // MARK: - The command line

    @Test func readsTheHookCommandLine() throws {
        let claude = try #require(HookHelper.Invocation(["hook", "--host", "claude", "--event", "PreToolUse"]))
        #expect(claude.host == .claude)
        #expect(claude.event == "PreToolUse")
        let codex = try #require(HookHelper.Invocation(["hook", "--event", "Stop", "--host", "codex"]))
        #expect(codex.host == .codex)
        #expect(codex.event == "Stop")
        #expect(try #require(HookHelper.Invocation(["hook", "--host", "codex"])).event == nil)
    }

    @Test(arguments: [
        [], ["hook"], ["--host", "claude"], ["serve", "--host", "claude"], ["hook", "--host"], ["hook", "--host", "cursor"],
        ["hook", "--event", "Stop"], ["hook", "--host", "claude", "--blocking"], ["hook", "--host", "claude", "--verbose", "1"],
    ])
    func anythingElseIsntAHook(arguments: [String]) {
        #expect(HookHelper.Invocation(arguments) == nil)
    }

    @Test func anythingElseDrainsTheInputAndSendsNothing() async throws {
        let feeder = Feeder([UInt8](repeating: 0x20, count: 1 << 20))
        let outcome = HookHelper.run(
            arguments: ["--version"], environment: [:], input: feeder.readEnd, socketPath: { _ in "/nonexistent/hooks.sock" }
        )
        #expect(outcome == .ignored)
        #expect(await feeder.wroteEverything())
    }

    // MARK: - Running

    @Test func sendsTheEventToRoga() async throws {
        let listener = try HookListener(supportFolder: try makeTemporaryFolder())
        defer { listener.stop() }
        let received = Received(from: listener)
        let feeder = Feeder(claudePreToolUse)
        let outcome = HookHelper.run(
            arguments: ["hook", "--host", "claude", "--event", "PreToolUse"],
            environment: ["CLAUDE_CODE_ENTRYPOINT": "cli"],
            input: feeder.readEnd,
            socketPath: { _ in listener.socketPath },
            parent: getpid(),
            now: date(1_800_000_000.25)
        )
        let me = try #require(ProcessEntry(pid: getpid()))
        let expected = HookEvent(
            host: .claude, event: "PreToolUse", session: "76027137-d5e5-4825-af08-3adb4f0fbc31", cwd: "/Users/me/w",
            pid: getpid(), processStart: me.start, tool: "Bash", time: 1_800_000_000.25
        )
        #expect(outcome == .sent(expected))
        #expect(await eventually { received.all == [expected] })
        #expect(await feeder.wroteEverything())
    }

    @Test func sendsNothingWhileRogaGeneratesAMessage() async throws {
        let listener = try HookListener(supportFolder: try makeTemporaryFolder())
        defer { listener.stop() }
        let received = Received(from: listener)
        let feeder = Feeder(claudePrompt)
        let outcome = HookHelper.run(
            arguments: ["hook", "--host", "claude", "--event", "UserPromptSubmit"],
            environment: ["ROGA_GENERATING": "1"],
            input: feeder.readEnd,
            socketPath: { _ in listener.socketPath }
        )
        #expect(outcome == .generating)
        try await Task.sleep(for: .milliseconds(300))
        #expect(received.all.isEmpty)
    }

    @Test func returnsAtOnceWhenRogaIsntRunning() async throws {
        let path = HookSocket.path(supportFolder: try makeTemporaryFolder())
        let feeder = Feeder([UInt8](repeating: 0x20, count: 1 << 20))
        let started = ContinuousClock.now
        let outcome = HookHelper.run(
            arguments: ["hook", "--host", "codex", "--event", "PreToolUse"],
            environment: [:],
            input: feeder.readEnd,
            socketPath: { _ in path }
        )
        #expect(outcome == .noSocket)
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(await feeder.wroteEverything())
    }

    @Test func returnsAtOnceWhenASocketIsLeftButNothingListens() throws {
        let path = HookSocket.path(supportFolder: try makeTemporaryFolder())
        makeAbandonedSocket(at: path)
        #expect(FileManager.default.fileExists(atPath: path))
        let feeder = Feeder(claudePrompt)
        let started = ContinuousClock.now
        let outcome = HookHelper.run(
            arguments: ["hook", "--host", "claude", "--event", "UserPromptSubmit"],
            environment: [:],
            input: feeder.readEnd,
            socketPath: { _ in path },
            now: date(5)
        )
        guard case .notSent(let event) = outcome else {
            Issue.record("Expected the event not to be sent, got \(outcome)")
            return
        }
        #expect(event.session == "s1")
        #expect(ContinuousClock.now - started < .milliseconds(500))
    }

    @Test func givesUpOnASocketPathTooLongForAnAddress() {
        let path = "/tmp/" + String(repeating: "a", count: 120) + "/hooks.sock"
        let started = ContinuousClock.now
        #expect(!HookHelper.send(HookEvent(host: .claude, event: "Stop", time: 1), toSocketAt: path))
        #expect(ContinuousClock.now - started < .milliseconds(100))
    }

    @Test func aPayloadThatIsntJSONStillSendsTheEventName() async throws {
        let listener = try HookListener(supportFolder: try makeTemporaryFolder())
        defer { listener.stop() }
        let received = Received(from: listener)
        let feeder = Feeder("this isn't JSON {")
        let outcome = HookHelper.run(
            arguments: ["hook", "--host", "codex", "--event", "Stop"],
            environment: [:],
            input: feeder.readEnd,
            socketPath: { _ in listener.socketPath },
            parent: getpid(),
            now: date(7)
        )
        guard case .sent(let event) = outcome else {
            Issue.record("Expected the event to be sent, got \(outcome)")
            return
        }
        #expect(event.host == .codex)
        #expect(event.event == "Stop")
        #expect(event.session == nil)
        #expect(event.pid == getpid())
        #expect(await eventually { received.all == [event] })
    }

    @Test func drainsAHugePayloadAndStillSaysWhichSessionAndTool() async throws {
        let listener = try HookListener(supportFolder: try makeTemporaryFolder())
        defer { listener.stop() }
        let received = Received(from: listener)
        // Bigger than what the helper keeps, like a tool result with a whole
        // file in it.
        let content = String(repeating: "x", count: 20 << 20)
        let json = #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"/w/big.txt","session_id":"not this one"},"tool_response":{"content":""#
            + content + #""},"tool_use_id":"t1"}"#
        let feeder = Feeder(json)
        let outcome = HookHelper.run(
            arguments: ["hook", "--host", "claude", "--event", "PostToolUse"],
            environment: [:],
            input: feeder.readEnd,
            socketPath: { _ in listener.socketPath },
            parent: getpid(),
            now: date(9)
        )
        guard case .sent(let event) = outcome else {
            Issue.record("Expected the event to be sent, got \(outcome)")
            return
        }
        #expect(await feeder.wroteEverything())
        #expect(event.event == "PostToolUse")
        #expect(event.session == "s1")
        #expect(event.cwd == "/w")
        #expect(event.tool == "Read")
        #expect(await eventually { received.all == [event] })
    }

    @Test func readsAllOfAnInputThatsJustUnderTheLimit() {
        let feeder = Feeder([UInt8](repeating: 0x20, count: 3 << 20))
        let input = HookHelper.readInput(from: feeder.readEnd, keeping: 3 << 20)
        #expect(input.bytes.count == 3 << 20)
        #expect(input.isWhole)
        let cut = Feeder([UInt8](repeating: 0x20, count: (3 << 20) + 1))
        let partial = HookHelper.readInput(from: cut.readEnd, keeping: 3 << 20)
        #expect(partial.bytes.count == 3 << 20)
        #expect(!partial.isWhole)
    }

    // MARK: - Payloads

    @Test func readsClaudeCodesPayloads() throws {
        let start = try #require(try parsed(#"{"session_id":"s1","transcript_path":"/t","cwd":"/w","hook_event_name":"SessionStart","source":"clear","model":"claude-opus-5-5","session_title":"New"}"#))
        #expect(start.source == "clear")
        #expect(start.cwd == "/w")

        let notification = try #require(try parsed(#"{"session_id":"abc123","transcript_path":"...","cwd":"/Users/...","hook_event_name":"Notification","message":"Claude needs your permission","title":"Permission needed","notification_type":"permission_prompt"}"#))
        #expect(notification.notification == "permission_prompt")

        let stop = try #require(try parsed(#"{"session_id":"s1","transcript_path":"/t","cwd":"/w","permission_mode":"default","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"The secret is out","background_tasks":[{"id":"b1","type":"bash"},{"id":"b2","type":"agent"}],"session_crons":[]}"#))
        #expect(stop.backgroundTasks == 2)

        let quietStop = try #require(try parsed(#"{"session_id":"s1","cwd":"/w","hook_event_name":"Stop","background_tasks":[]}"#))
        #expect(quietStop.backgroundTasks == 0)

        let failure = try #require(try parsed(#"{"session_id":"s1","transcript_path":"/t","cwd":"/w","hook_event_name":"StopFailure","error":"rate_limit","error_details":"429 Too Many Requests","last_assistant_message":""}"#))
        #expect(failure.error == "rate_limit")

        let end = try #require(try parsed(#"{"session_id":"s1","transcript_path":"/t","cwd":"/w","hook_event_name":"SessionEnd","reason":"prompt_input_exit"}"#))
        #expect(end.reason == "prompt_input_exit")

        let moved = try #require(try parsed(#"{"session_id":"s1","transcript_path":"/t","cwd":"/w","hook_event_name":"CwdChanged","old_cwd":"/w","new_cwd":"/w/app"}"#))
        #expect(moved.cwd == "/w/app")

        let subagent = try #require(try parsed(#"{"session_id":"s1","transcript_path":"/t","cwd":"/w","permission_mode":"default","hook_event_name":"PreToolUse","agent_id":"agent-a1b2","agent_type":"Explore","tool_name":"Grep","tool_input":{"pattern":"TODO"},"tool_use_id":"t"}"#))
        #expect(subagent.subagent == "agent-a1b2")
        #expect(subagent.tool == "Grep")
    }

    @Test func readsCodexsPayloads() throws {
        let request = try #require(try parsed(#"{"session_id":"019a5c3e-7f2d-7c11-9a4b-0c2b9e1f6d3a","turn_id":"t1","transcript_path":null,"cwd":"/w/app","hook_event_name":"PermissionRequest","model":"gpt-6-astra","permission_mode":"default","tool_name":"exec_command","tool_input":{"command":["cat","secret.txt"],"description":"Read the secret"}}"#, host: .codex))
        #expect(request == HookEvent(host: .codex, event: "PermissionRequest", session: "019a5c3e-7f2d-7c11-9a4b-0c2b9e1f6d3a", cwd: "/w/app", tool: "exec_command", time: 1))

        let end = try #require(try parsed(#"{"session_id":"s2","transcript_path":null,"cwd":"/w","hook_event_name":"SessionEnd","reason":"other"}"#, host: .codex))
        #expect(end.reason == "other")

        let subagent = try #require(try parsed(#"{"session_id":"s2","turn_id":"t2","transcript_path":null,"cwd":"/w","hook_event_name":"SubagentStart","model":"gpt-6-astra","permission_mode":"default","agent_id":"x-1","agent_type":"worker"}"#, host: .codex))
        #expect(subagent.subagent == "x-1")

        let stop = try #require(try parsed(#"{"session_id":"s2","turn_id":"t3","transcript_path":"/t","cwd":"/w","hook_event_name":"Stop","model":"gpt-6-astra","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}"#, host: .codex))
        #expect(stop == HookEvent(host: .codex, event: "Stop", session: "s2", cwd: "/w", time: 1))
    }

    @Test func takesFieldsThatOnlySomeEventsHaveOnlyFromThoseEvents() throws {
        // Elsewhere, `error` is a tool's failure and `reason` a denial's.
        let failure = try #require(try parsed(#"{"session_id":"s1","cwd":"/w","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{},"error":"Command failed: secret","is_interrupt":false}"#))
        #expect(failure.error == nil)
        let denied = try #require(try parsed(#"{"session_id":"s1","cwd":"/w","hook_event_name":"PermissionDenied","tool_name":"Bash","tool_input":{},"reason":"Auto mode denied the secret"}"#))
        #expect(denied.reason == nil)
        let notStop = try #require(try parsed(#"{"session_id":"s1","hook_event_name":"SubagentStop","background_tasks":[1,2],"source":"x","notification_type":"y"}"#))
        #expect(notStop.backgroundTasks == nil)
        #expect(notStop.source == nil)
        #expect(notStop.notification == nil)
    }

    @Test func neverSendsPromptsOrToolInput() throws {
        for json in [claudePrompt, claudePreToolUse] {
            let event = try #require(try parsed(json))
            let line = String(decoding: try #require(HookHelper.line(for: event)), as: UTF8.self)
            #expect(!line.contains("secret"))
            #expect(!line.lowercased().contains("secret"))
        }
    }

    @Test func prefersTheEventNameInThePayload() throws {
        let named = try #require(try parsed(#"{"session_id":"s1","hook_event_name":"SubagentStop"}"#, event: "Stop"))
        #expect(named.event == "SubagentStop")
        let unnamed = try #require(try parsed(#"{"session_id":"s1"}"#, event: "Stop"))
        #expect(unnamed.event == "Stop")
        #expect(try parsed(#"{"session_id":"s1"}"#) == nil)
    }

    @Test func dropsFieldsTooLongToBeReal() throws {
        let folder = "/" + String(repeating: "f", count: 5000)
        let tool = String(repeating: "t", count: 300)
        let event = try #require(try parsed(#"{"session_id":"s1","cwd":"\#(folder)","hook_event_name":"PreToolUse","tool_name":"\#(tool)"}"#))
        #expect(event.cwd == nil)
        #expect(event.tool == nil)
        #expect(event.session == "s1")
        let empty = try #require(try parsed(#"{"session_id":"","cwd":"","hook_event_name":"Stop","agent_id":""}"#))
        #expect(empty.session == nil)
        #expect(empty.cwd == nil)
        #expect(empty.subagent == nil)
    }

    @Test func findsTheCommonFieldsInAPayloadItCantRead() {
        let bytes = Array(#"{"session_id" : "s\"1","cwd":"/w\/x","hook_event_name":"PostToolUse","tool_input":{"cwd":"/elsewhere"#.utf8)
        let payload = HookHelper.Payload(HookHelper.Input(bytes: bytes, isWhole: false))
        #expect(payload.session == "s\"1")
        #expect(payload.cwd == "/w/x")
        #expect(payload.event == "PostToolUse")
        #expect(payload.tool == nil)
        #expect(HookHelper.Payload(HookHelper.Input(bytes: Array("{\"session_id\":\"unfinished".utf8), isWhole: false)).session == nil)
    }

    // MARK: - The line

    @Test func writesOneLineOfJSONThatFitsTheSocketsBuffer() throws {
        let long = String(repeating: "é", count: 128)
        let event = HookEvent(
            host: .codex, event: long, session: long, cwd: "/" + String(repeating: "d", count: 4095), pid: 123,
            processStart: 1_793_929_461.013, tool: long, notification: long, source: long, reason: long, subagent: long,
            backgroundTasks: 3, error: "line\nbreak", time: 1_800_000_000.5
        )
        let line = try #require(HookHelper.line(for: event))
        #expect(line.last == UInt8(ascii: "\n"))
        #expect(line.filter { $0 == UInt8(ascii: "\n") }.count == 1)
        #expect(line.count < 8192)
        #expect(try JSONDecoder().decode(HookEvent.self, from: Data(line)) == event)
    }

    // MARK: - Finding the socket

    @Test func findsTheBundleIDOfTheAppItsIn() throws {
        let folder = try makeTemporaryFolder()
        let contents = folder.appending(path: "Roga Copy.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "Helpers"), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "sh.roga.copy"], format: .xml, options: 0)
        try info.write(to: contents.appending(path: "Info.plist"))
        let helper = contents.appending(path: "Helpers/roga").path(percentEncoded: false)
        #expect(HookHelper.bundleIdentifier(ofAppContaining: helper) == "sh.roga.copy")
        #expect(HookHelper.bundleIdentifier(executable: helper, environment: ["ROGA_BUNDLE_ID": "sh.roga.other"]) == "sh.roga.copy")
        // A tool deeper in an app isn't its helper.
        #expect(HookHelper.bundleIdentifier(ofAppContaining: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest") == nil)
        #expect(HookHelper.bundleIdentifier(ofAppContaining: contents.appending(path: "MacOS/roga").path(percentEncoded: false)) == "sh.roga.copy")
    }

    @Test func fallsBackToTheEnvironmentAndThenRogasOwnID() {
        #expect(HookHelper.bundleIdentifier(executable: "/usr/local/bin/roga", environment: ["ROGA_BUNDLE_ID": "sh.roga.copy"]) == "sh.roga.copy")
        #expect(HookHelper.bundleIdentifier(executable: nil, environment: [:]) == "sh.roga.app")
        #expect(HookHelper.bundleIdentifier(executable: nil, environment: ["ROGA_BUNDLE_ID": "../elsewhere"]) == "sh.roga.app")
        #expect(HookHelper.bundleIdentifier(executable: nil, environment: ["ROGA_BUNDLE_ID": ""]) == "sh.roga.app")
    }

    // MARK: - roga --version

    @Test func onlyALoneVersionOptionAsksForTheVersion() {
        #expect(HookHelper.asksForVersion(["--version"]))
        #expect(!HookHelper.asksForVersion([]))
        #expect(!HookHelper.asksForVersion(["--help"]))
        #expect(!HookHelper.asksForVersion(["--version", "extra"]))
        #expect(!HookHelper.asksForVersion(["hook", "--host", "claude", "--version"]))
    }

    @Test func saysWhichCopyOfRogaItCameWith() throws {
        let folder = try makeTemporaryFolder()
        let app = folder.appending(path: "Roga Copy.app", directoryHint: .isDirectory)
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "Helpers"), withIntermediateDirectories: true)
        let appFolder = (folder.path(percentEncoded: false) as NSString).appendingPathComponent("Roga Copy.app")
        let helper = contents.appending(path: "Helpers/roga").path(percentEncoded: false)

        func writeInfo(_ info: [String: String]) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appending(path: "Info.plist"))
        }

        try writeInfo(["CFBundleIdentifier": "sh.roga.copy", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7"])
        #expect(HookHelper.versionLine(executable: helper) == "roga 0.1.0 (7), in \(appFolder)")
        // The app's own executable finds the same app, as it does its socket.
        #expect(HookHelper.versionLine(executable: contents.appending(path: "MacOS/Roga").path(percentEncoded: false)) == "roga 0.1.0 (7), in \(appFolder)")

        try writeInfo(["CFBundleIdentifier": "sh.roga.copy", "CFBundleShortVersionString": "0.2.0"])
        #expect(HookHelper.versionLine(executable: helper) == "roga 0.2.0, in \(appFolder)")
        try writeInfo(["CFBundleIdentifier": "sh.roga.copy"])
        #expect(HookHelper.versionLine(executable: helper) == "roga, in \(appFolder)")
    }

    @Test func saysWhenItIsntInsideAnApp() throws {
        #expect(HookHelper.versionLine(executable: nil) == "roga, not inside an app")
        #expect(HookHelper.versionLine(executable: "/usr/local/bin/roga") == "roga, not inside an app")
        #expect(HookHelper.versionLine(executable: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest") == "roga, not inside an app")
        // A folder named like an app, with no Info.plist, isn't one.
        let folder = try makeTemporaryFolder()
        let helpers = folder.appending(path: "Empty.app/Contents/Helpers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        #expect(HookHelper.versionLine(executable: helpers.appending(path: "roga").path(percentEncoded: false)) == "roga, not inside an app")
    }

    @Test func theSocketIsInRogasFolderInApplicationSupport() {
        let path = HookHelper.defaultSocketPath(environment: ["ROGA_BUNDLE_ID": "sh.roga.test"])
        #expect(path == HookSocket.path(supportFolder: HookSocket.supportFolder(bundleIdentifier: "sh.roga.test")))
        #expect(path.hasSuffix("/Library/Application Support/sh.roga.test/hooks.sock"))
        #expect(path.utf8.count <= HookSocket.maximumPathLength)
    }

    @Test func socketAddressesHoldAtMost103Bytes() {
        #expect(HookSocket.maximumPathLength == 103)
        #expect(HookSocket.withAddress(of: "/" + String(repeating: "a", count: 102)) { _, _ in true } == true)
        #expect(HookSocket.withAddress(of: "/" + String(repeating: "a", count: 103)) { _, _ in true } == nil)
    }
}
