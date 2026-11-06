import GitRunner

/// Asks an agent for a commit message and cleans up its reply (decision 41).
public enum CommitMessageWriter {
    /// Runs the agent and returns the cleaned message. A reply whose subject
    /// is empty, or ends in an ellipsis as if the model was cut off, gets one
    /// more try, which models often get right. A second subject with an
    /// ellipsis is still returned, since the author can finish it, but a
    /// second empty one throws `CommitMessageError.empty`.
    ///
    /// - Parameter run: Runs a command with bytes for its standard input.
    ///   The app passes `{ try await programs.run($0, input: $1) }`.
    /// - Throws: `CommitMessageError`, or `CancellationError` when the task is
    ///   cancelled, which stops the agent.
    @concurrent
    public static func write(
        _ request: CommitMessageRequest,
        with agent: CommitMessageAgent,
        run: @Sendable (ProgramCommand, [UInt8]) async throws -> ProgramResult
    ) async throws -> WrittenMessage {
        try await write(request, with: agent, makeToken: CommitMessagePrompt.makeToken, run: run)
    }

    /// The same, with the tags' tokens from `makeToken`, so that tests can
    /// know them.
    @concurrent
    static func write(
        _ request: CommitMessageRequest,
        with agent: CommitMessageAgent,
        makeToken: @Sendable () -> String,
        run: @Sendable (ProgramCommand, [UInt8]) async throws -> ProgramResult
    ) async throws -> WrittenMessage {
        // Codex's MCP servers as they are now, since naming one it no longer
        // has stops it from starting.
        var agent = agent
        if agent.kind == .codex, let file = agent.codexConfigurationFile {
            agent.mcpServers = CodexConfiguration.mcpServers(inFile: file) ?? []
        }
        let command = CommitMessageCommand.command(
            for: agent,
            worktree: request.worktree,
            style: request.style,
            hasDraft: request.trimmedDraft != nil
        )
        var duration = Duration.zero
        var message = ""
        for _ in 0..<2 {
            let input = Array(CommitMessagePrompt.input(for: request, token: makeToken()).utf8)
            let result: ProgramResult
            do {
                result = try await run(command, input)
            } catch let error as ProgramError {
                throw CommitMessageError.program(error)
            }
            duration += result.duration
            message = CommitMessageCleanup.clean(try CommitMessageReply.message(from: result, agent: agent.kind), draft: request.draft)
            let subject = CommitMessageCleanup.subject(of: message)
            if !subject.isEmpty, !subject.hasSuffix("..."), !subject.hasSuffix("\u{2026}") { break }
        }
        guard !CommitMessageCleanup.subject(of: message).isEmpty else { throw CommitMessageError.empty(agent.kind) }
        return WrittenMessage(text: message, duration: duration)
    }
}
