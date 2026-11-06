import Foundation
import GitRunner

/// A commit message an agent wrote, cleaned up.
public struct WrittenMessage: Sendable, Hashable {
    public var text: String
    /// How long the agent took, counting a second try.
    public var duration: Duration

    public init(text: String, duration: Duration) {
        self.text = text
        self.duration = duration
    }
}

/// Why an agent didn't write a commit message.
public enum CommitMessageError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The agent ran and said it failed. The message is one sentence that says
    /// what to do about it, and the output is what the agent printed, for
    /// someone who wants the details.
    case agentFailed(AgentKind, message: String, output: String)
    /// The agent's reply had nothing left once it was cleaned up, twice.
    case empty(AgentKind)
    /// The agent couldn't start, ran past its time limit, or printed too much.
    case program(ProgramError)

    public var description: String {
        switch self {
        case .agentFailed(_, let message, _): message
        case .empty(let kind): "\(kind.name) replied without a message."
        case .program(let error): error.description
        }
    }

    /// What the agent printed, or nil when there's nothing more to show than
    /// `description`.
    public var output: String? {
        switch self {
        case .agentFailed(_, _, let output): output.isEmpty ? nil : output
        case .program(.timedOut(_, _, let errorOutput)): errorOutput.isEmpty ? nil : errorOutput
        case .empty, .program: nil
        }
    }
}

/// Reads an agent's reply, which says how it failed as often as it holds a
/// message (decision 41).
public enum CommitMessageReply {
    /// The message in an agent's reply, before cleanup.
    ///
    /// Claude Code prints JSON, and its failures, such as not being signed in,
    /// are its `result` too, so a message needs an exit status of 0 and
    /// `is_error` false, or the error would land in the message box. Codex
    /// prints only the message on standard output, and on failure an
    /// `ERROR: {json}` line on standard error with `error.message`.
    ///
    /// A failure becomes one sentence that says what to do: sign in, wait for
    /// a usage limit, or choose a newer Codex on the Agents page. Anything else
    /// is the first line of what the agent said.
    public static func message(from result: ProgramResult, agent: AgentKind) throws(CommitMessageError) -> String {
        switch agent {
        case .claude: try claudeMessage(from: result)
        case .codex: try codexMessage(from: result)
        }
    }

    // MARK: Claude Code

    private static func claudeMessage(from result: ProgramResult) throws(CommitMessageError) -> String {
        let errorOutput = CommitMessageText.trimmed(result.errorOutput)
        guard let reply = jsonObject(in: result.output) else {
            let output = [CommitMessageText.trimmed(result.text), errorOutput].filter { !$0.isEmpty }.joined(separator: "\n")
            if result.succeeded {
                throw .agentFailed(
                    .claude,
                    message: "Claude Code replied with something Roga can't read: " + (CommitMessageText.firstLine(output) ?? "nothing") + ".",
                    output: output
                )
            }
            throw failure(.claude, said: errorOutput.isEmpty ? result.text : errorOutput, status: result.status, httpStatus: nil, output: output)
        }
        let text = reply["result"] as? String
        let isError = reply["is_error"] as? Bool ?? false
        if result.succeeded, !isError, let text { return text }

        let said = text.map(CommitMessageText.trimmed) ?? ""
        let output = [said, errorOutput].filter { !$0.isEmpty }.joined(separator: "\n")
        throw failure(
            .claude,
            said: said.isEmpty ? errorOutput : said,
            status: result.status,
            httpStatus: reply["api_error_status"] as? Int,
            output: output
        )
    }

    /// The JSON object Claude Code printed: all of its output, or else its
    /// last line that looks like one, in case something printed before it.
    private static func jsonObject(in output: [UInt8]) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: Data(output)) as? [String: Any] { return object }
        let lines = CommitMessageText.lines(String(decoding: output, as: UTF8.self))
        guard let last = lines.last(where: { $0.hasPrefix("{") }) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any]
    }

    // MARK: Codex

    private static func codexMessage(from result: ProgramResult) throws(CommitMessageError) -> String {
        if result.succeeded { return result.text }

        // Codex echoes the whole prompt to standard error, standard input
        // included, so only a line that starts with `ERROR: ` counts, and the
        // last one, which comes after the echo, is Codex's own.
        let lines = CommitMessageText.lines(result.errorOutput)
        let errors = lines.filter { $0.hasPrefix("ERROR: ") }
        let last = errors.last.map { codexError(String($0.dropFirst("ERROR: ".count))) }
        let tail = lines.map(CommitMessageText.trimmedAtEnd).filter { !$0.isEmpty }.suffix(20)
        let output = (errors.isEmpty ? Array(tail) : errors).joined(separator: "\n")
            + (result.output.isEmpty ? "" : "\n" + CommitMessageText.trimmed(result.text))
        let said = last?.message ?? tail.last ?? result.text
        throw failure(.codex, said: said, status: result.status, httpStatus: last?.status, output: output)
    }

    /// What an `ERROR: ` line says: the JSON Codex prints for an error from
    /// its server, or plain text.
    private static func codexError(_ text: String) -> (message: String, status: Int?) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return (text, nil)
        }
        let inner = object["error"] as? [String: Any]
        let message = inner?["message"] as? String ?? object["message"] as? String ?? text
        return (message, object["status"] as? Int)
    }

    // MARK: Explaining failures

    private static func failure(_ kind: AgentKind, said: String, status: ExitStatus, httpStatus: Int?, output: String) -> CommitMessageError {
        .agentFailed(kind, message: explanation(kind, said: said, status: status, httpStatus: httpStatus), output: output)
    }

    static func explanation(_ kind: AgentKind, said: String, status: ExitStatus, httpStatus: Int?) -> String {
        let lowercased = said.lowercased()
        if isSignedOut(kind, lowercased, httpStatus) {
            let login = switch kind {
            case .claude: "claude auth login"
            case .codex: "codex login"
            }
            return "\(kind.name) isn't signed in. Run \(login) in Terminal."
        }
        if isLimited(lowercased, httpStatus) {
            return "\(kind.name) has reached a usage limit, so try again once it resets, or choose another model."
        }
        if kind == .codex, lowercased.contains("requires a newer version of codex") {
            return "This model needs a newer version of Codex, which Roga can use once you choose it on the Agents page."
        }
        return CommitMessageText.firstLine(said) ?? "\(kind.name) \(status) without saying why."
    }

    private static func isSignedOut(_ kind: AgentKind, _ text: String, _ httpStatus: Int?) -> Bool {
        if httpStatus == 401 { return true }
        switch kind {
        case .claude:
            return text.contains("not logged in") || text.contains("failed to authenticate") || text.contains("oauth")
        case .codex:
            return text.contains("not logged in") || text.contains("unauthorized") || containsNumber(401, in: text)
        }
    }

    private static func isLimited(_ text: String, _ httpStatus: Int?) -> Bool {
        if httpStatus == 429 { return true }
        // Not "limit reached" alone, which a model's context window can be too.
        let phrases = ["rate limit", "rate_limit", "usage limit", "usage_limit", "too many requests", "quota"]
        if phrases.contains(where: text.contains) || containsNumber(429, in: text) { return true }
        // "You've hit your limit · resets 3pm", and "You've hit your usage limit".
        if let hit = text.firstRange(of: "hit your"), text[hit.upperBound...].contains("limit") { return true }
        return false
    }

    /// Whether the text has the number on its own, rather than inside a longer
    /// one.
    private static func containsNumber(_ number: Int, in text: String) -> Bool {
        let digits = String(number)
        var rest = text[...]
        while let range = rest.firstRange(of: digits) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if before?.isNumber != true, after?.isNumber != true { return true }
            rest = text[range.upperBound...]
        }
        return false
    }
}
