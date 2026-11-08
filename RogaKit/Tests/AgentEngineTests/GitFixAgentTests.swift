import Foundation
import GitRunner
import Synchronization
import Testing
@testable import AgentEngine

/// Asking an agent how to fix something git refused, and what Roga will run of
/// what it says (decision 63).
struct GitFixAgentTests {
    let request = GitFixRequest(
        worktree: "/work",
        command: ["pull", "--ff-only"],
        said: "fatal: bad object HEAD",
        facts: [.init(command: "git version", output: "git version 2.50.0")]
    )
    let claude = CommitMessageAgent(kind: .claude, executable: "/usr/local/bin/claude", model: "sonnet")

    final class Inputs: Sendable {
        let inputs = Mutex<[(ProgramCommand, String)]>([])
    }

    /// A run that answers with Claude Code's JSON around `reply`.
    func claudeReply(_ reply: String, _ inputs: Inputs = Inputs()) -> @Sendable (ProgramCommand, [UInt8]) async throws -> ProgramResult {
        { command, input in
            inputs.inputs.withLock { $0.append((command, String(decoding: input, as: UTF8.self))) }
            let json = #"{"type":"result","is_error":false,"result":\#(String(reflecting: reply))}"#
            return ProgramResult(status: .exited(0), output: Array(json.utf8), errorOutput: "", duration: .seconds(12))
        }
    }

    // MARK: What's sent and read back

    @Test func sendsTheFailureAndEachFactInBlocksOfTheirOwn() {
        #expect(GitFixPrompt.input(for: request, token: "feedface") == """
            <failure-feedface>
            Worktree: /work
            Command that failed: git pull --ff-only
            </failure-feedface>

            <git-said-feedface>
            fatal: bad object HEAD
            </git-said-feedface>

            <fact-1-feedface>
            $ git version
            git version 2.50.0
            </fact-1-feedface>

            """)
    }

    @Test func sendsAFixThatWasAlreadyTriedInItsOwnBlock() {
        var request = request
        request.facts = []
        request.attempts = [.init(command: ["rm", "--cached", "a b"], said: "error: use -f")]
        #expect(GitFixPrompt.input(for: request, token: "feedface").contains("""
            <attempt-1-feedface>
            $ git rm --cached 'a b'
            error: use -f
            </attempt-1-feedface>
            """))
    }

    @Test func readsTheExplanationAndEachCommand() {
        let reply = """
            Sure.
            <why>
            The index has a gitlink for an ignored folder.
            </why>
            <commands>
            ["rm", "-r", "--cached", "-f", "a b/c"]
            ["git", "fsck"]
            </commands>
            """
        #expect(GitFixPrompt.parse(reply) == .init(
            explanation: "The index has a gitlink for an ignored folder.",
            commands: [["rm", "-r", "--cached", "-f", "a b/c"], ["fsck"]]
        ))
    }

    @Test func anEmptyBlockMeansNoCommands() {
        #expect(GitFixPrompt.parse("<why>No idea.</why>\n<commands>\n</commands>") == .init(explanation: "No idea.", commands: []))
    }

    @Test func aCodeFenceAroundTheCommandsIsIgnored() {
        #expect(GitFixPrompt.parse("<commands>\n```json\n[\"fsck\"]\n```\n</commands>")?.commands == [["fsck"]])
    }

    @Test func aLineThatIsntAListOfArgumentsIsntGuessedAt() {
        #expect(GitFixPrompt.parse("<why>x</why><commands>\ngit rm --cached 'a b'\n</commands>") == nil)
        #expect(GitFixPrompt.parse("<commands>\n[]\n</commands>") == nil)
        #expect(GitFixPrompt.parse("I think you should run git fsck.") == nil)
    }

    @Test func runsTheAgentWithNoToolsAndTheFactsOnItsInput() async throws {
        let inputs = Inputs()
        let fix = try await GitFixWriter.propose(
            request,
            with: claude,
            makeToken: { "feedface" },
            run: claudeReply("<why>Gone.</why><commands>\n[\"fsck\"]\n</commands>", inputs)
        )
        #expect(fix == AgentGitFix(explanation: "Gone.", commands: [ProposedGitCommand(arguments: ["fsck"])], duration: .seconds(12)))
        let (command, input) = try #require(inputs.inputs.withLock { $0.first })
        #expect(command.arguments.contains("--tools="))
        #expect(command.arguments.contains(GitFixPrompt.instructions))
        #expect(command.arguments.last == GitFixPrompt.task)
        #expect(command.timeout == GitFixWriter.shortestTimeLimit)
        #expect(input.hasPrefix("<failure-feedface>"))
    }

    @Test func aReplyItCantReadIsAFailure() async throws {
        await #expect(throws: CommitMessageError.agentFailed(.claude, message: "Claude Code replied with something Roga can't read as commands.", output: "Run git fsck.")) {
            try await GitFixWriter.propose(request, with: claude, run: claudeReply("Run git fsck."))
        }
    }

    // MARK: What Roga will run

    @Test(arguments: [
        ["rm", "-r", "--cached", "-f", "prototypes/git-access/.build"],
        ["reset"],
        ["restore", "--staged", "a.txt"],
        ["update-index", "--force-remove", "a.txt"],
        ["fetch", "origin", "+refs/heads/main:refs/remotes/origin/main"],
        ["pull", "--ff-only", "origin", "main"],
        ["merge", "--abort"],
        ["rebase", "--continue"],
        ["cherry-pick", "-s", "abc"],
        ["worktree", "prune"],
        ["submodule", "update", "--init"],
        ["remote", "prune", "origin"],
        ["fetch", "-p"],
        // After `--` it's a path, whatever it looks like.
        ["rm", "--cached", "--", "--exec", "-x"],
        ["merge", "-X", "theirs", "topic"],
        ["merge", "--strategy-option=theirs", "topic"],
    ])
    func runs(_ arguments: [String]) {
        #expect(ProposedGitCommand(arguments: arguments).refusal == nil)
    }

    @Test(arguments: [
        [],
        [""],
        // Nothing goes before the subcommand.
        ["-c", "core.pager=sh", "status"],
        ["-C", "/tmp", "rm", "a"],
        ["--git-dir=/tmp/x", "rm", "a"],
        ["--exec-path=/tmp", "rm", "a"],
        ["--config-env=core.editor=X", "rm", "a"],
        // Not on the list, or an alias, which can start anything.
        ["config", "core.sshCommand", "sh"],
        ["filter-branch", "--tree-filter", "sh", "HEAD"],
        ["bisect", "run", "sh"],
        ["mergetool"],
        ["difftool"],
        ["archive", "--remote=x", "--exec=sh", "HEAD"],
        ["st"],
        // Options that start programs or wait for someone.
        ["rebase", "--exec", "sh", "main"],
        ["rebase", "--exec=sh", "main"],
        ["rebase", "-x", "sh", "main"],
        ["rebase", "-xsh", "main"],
        ["rebase", "-ix", "sh", "main"],
        ["rebase", "--interactive", "main"],
        ["rebase", "-s", "evil", "main"],
        ["merge", "-s", "evil", "topic"],
        ["merge", "--strategy=evil", "topic"],
        ["merge", "--edit", "topic"],
        ["pull", "--upload-pack=sh", "origin"],
        ["fetch", "--upload-pack=sh", "origin"],
        ["fetch", "--upload-pa=sh", "origin"],
        ["fetch", "--multiple", "origin", "ext::sh"],
        ["add", "-p"],
        ["add", "--patch"],
        ["add", "-i"],
        ["reset", "-p"],
        ["checkout", "-p"],
        ["stash", "-p"],
        ["clean", "-i"],
        ["cherry-pick", "-e", "abc"],
        ["revert", "--edit", "abc"],
        ["branch", "--edit-description"],
        // A verb that runs whatever it's given, or that isn't a repair.
        ["submodule", "foreach", "sh"],
        ["submodule", "--quiet", "foreach", "sh"],
        ["submodule"],
        ["remote", "add", "x", "ext::sh"],
        ["remote", "set-url", "origin", "ext::sh"],
        ["worktree", "add", "/tmp/x"],
        // A transport can start a program too.
        ["fetch", "ext::sh -c evil"],
        ["pull", "fd::3"],
        ["fetch", "https://example.com/a.git"],
        ["fetch", "host:path/a.git"],
        // Two commands in one.
        ["rm", "a\nb"],
    ] as [[String]])
    func refuses(_ arguments: [String]) {
        #expect(ProposedGitCommand(arguments: arguments).refusal != nil)
    }

    @Test func aCommandThatCantRunTakesTheRestWithIt() {
        let fix = AgentGitFix(
            explanation: "",
            commands: [ProposedGitCommand(arguments: ["fsck"]), ProposedGitCommand(arguments: ["config", "a", "b"])],
            duration: .zero
        )
        #expect(!fix.canRun)
    }

    @Test func nothingToRunIsntARun() {
        #expect(!AgentGitFix(explanation: "", commands: [], duration: .zero).canRun)
    }

    @Test(arguments: [
        (["rm", "-r", "--cached", "-f", "a"], true),
        (["rm", "a"], false),
        (["reset"], true),
        (["reset", "--hard"], false),
        (["restore", "--staged", "a"], true),
        (["restore", "a"], false),
        (["restore", "--staged", "--worktree", "a"], false),
        (["update-index", "--refresh"], true),
        (["stash", "push"], true),
        (["stash", "drop"], false),
        (["clean", "-fdx"], false),
        (["worktree", "prune"], true),
        (["worktree", "remove", "--force", "/tmp/a"], false),
        (["merge", "--abort"], false),
        // A path that happens to say --cached doesn't make it safe.
        (["rm", "--", "--cached"], false),
        (["config", "a", "b"], false),
    ] as [([String], Bool)])
    func saysWhetherItLosesAnything(_ arguments: [String], keeps: Bool) {
        #expect(ProposedGitCommand(arguments: arguments).keepsEverything == keeps)
    }
}
