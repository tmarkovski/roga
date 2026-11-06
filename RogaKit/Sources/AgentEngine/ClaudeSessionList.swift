import Foundation
import GitRunner

/// One Claude Code session, as `claude agents --json` lists it.
///
/// Every field is optional and a field of the wrong type reads as missing,
/// because the list is Claude Code's to change and Roga only needs enough of
/// it to correct a stale mark (decision 41).
public struct ClaudeListedSession: Sendable, Hashable, Decodable {
    /// The Claude Code process.
    public var pid: Int32?
    public var cwd: String?
    public var sessionId: String?
    /// `busy`, `idle` or `waiting`.
    public var status: String?
    /// What a waiting session waits for.
    public var waitingFor: String?
    /// `interactive` or `background`.
    public var kind: String?

    public init(pid: Int32? = nil, cwd: String? = nil, sessionId: String? = nil, status: String? = nil, waitingFor: String? = nil, kind: String? = nil) {
        self.pid = pid
        self.cwd = cwd
        self.sessionId = sessionId
        self.status = status
        self.waitingFor = waitingFor
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case pid, cwd, sessionId, status, waitingFor, kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            try? container.decodeIfPresent(String.self, forKey: key)
        }
        let number = try? container.decodeIfPresent(Int64.self, forKey: .pid)
        pid = number.flatMap { Int32(exactly: $0) }
        cwd = text(.cwd)
        sessionId = text(.sessionId)
        status = text(.status)
        waitingFor = text(.waitingFor)
        kind = text(.kind)
    }
}

/// Asking Claude Code which sessions are running, which is how Roga finds the
/// sessions it missed while it was closed and corrects a mark that a missed
/// hook left behind (decision 41). `claude agents --json` is the way Claude
/// Code offers to read sessions from outside, and it lists the desktop app's
/// sessions too.
public enum ClaudeSessionList {
    /// The sessions in what `claude agents --json` printed. Entries that aren't
    /// objects are skipped, and anything that isn't a list reads as no sessions.
    public static func parse(_ output: [UInt8]) -> [ClaudeListedSession] {
        sessions(in: output) ?? []
    }

    /// Runs `claude agents --json` at utility priority with a 5 s limit.
    ///
    /// - Returns: The sessions, or nil when Claude Code failed, took too long
    ///   or printed something other than a list. Nil isn't an empty list,
    ///   because an empty list would clear every Claude Code mark.
    @concurrent
    public static func list(executable: String, programs: Programs) async -> [ClaudeListedSession]? {
        await list(executable: executable, programs: programs, timeLimit: .seconds(5))
    }

    /// `list`, with a time limit that tests can shorten.
    @concurrent
    static func list(executable: String, programs: Programs, timeLimit: Duration) async -> [ClaudeListedSession]? {
        guard let result = try? await programs.run(command(executable: executable, timeLimit: timeLimit)),
              result.succeeded
        else { return nil }
        return sessions(in: result.output)
    }

    /// The command `list` runs.
    public static func command(executable: String, timeLimit: Duration = .seconds(5)) -> ProgramCommand {
        var command = ProgramCommand(executable, ["agents", "--json"])
        command.priority = .utility
        command.timeout = timeLimit
        command.outputLimit = 8 << 20
        return command
    }

    /// The sessions, or nil when the output isn't a JSON list.
    static func sessions(in output: [UInt8]) -> [ClaudeListedSession]? {
        guard let entries = try? JSONDecoder().decode([Lenient].self, from: Data(output)) else { return nil }
        return entries.compactMap(\.session)
    }

    /// One entry of the list, which may not be a session at all.
    private struct Lenient: Decodable {
        var session: ClaudeListedSession?

        init(from decoder: any Decoder) throws {
            session = try? ClaudeListedSession(from: decoder)
        }
    }
}
