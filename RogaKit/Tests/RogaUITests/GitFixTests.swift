import AgentEngine
import Foundation
import GitRunner
import RepositoryEngine
import Synchronization
import TestSupport
import Testing
@testable import RogaUI

/// Asking an agent about something git refused, against real git (decision 63).
@Suite(.timeLimit(.minutes(1)))
struct GitFixTests {
    static let brokenFolder = ".build/checkouts/dep"

    struct Worktree {
        var model: RepositoryModel
        var path: String
        var fix: GitFixModel { model.gitFix }

        func git(_ arguments: String...) async throws -> String {
            try await TestGit.make().run(GitCommand(arguments, in: path)).text
        }

        /// The button a refusal offers, if any.
        func offered(_ setup: GenerationSetup?) throws -> DialogButton? {
            guard case .message(let content) = try #require(model.dialog(fixingWith: setup)) else { return nil }
            return content.buttons.first { $0.title.hasPrefix("Fix with") }
        }

        /// What's showing now, once whatever's running has finished.
        func settledDialog() async throws -> DialogContent {
            await fix.work?.value
            return try #require(fix.dialog)
        }
    }

    /// A worktree whose index has a gitlink for an ignored folder that's a clone
    /// with no objects left, so that anything comparing the worktree with `HEAD`
    /// dies in it, as happened to Roga's own repository.
    func broken() async throws -> Worktree {
        let path = try makeTemporaryFolder() + "/work"
        let nested = path + "/" + Self.brokenFolder
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let git = try await TestGit.make()
        func run(_ arguments: [String], in folder: String) async throws -> String {
            try await git.run(GitCommand(arguments, in: folder)).text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for folder in [path, nested] {
            _ = try await run(["init", "--quiet", "--initial-branch=main"], in: folder)
            _ = try await run(["config", "user.name", "T"], in: folder)
            _ = try await run(["config", "user.email", "t@example.com"], in: folder)
            try Data("one\n".utf8).write(to: URL(filePath: folder + "/a.txt"))
            _ = try await run(["add", "a.txt"], in: folder)
            _ = try await run(["commit", "--quiet", "--message=First"], in: folder)
        }
        try Data(".build/\n".utf8).write(to: URL(filePath: path + "/.gitignore"))
        _ = try await run(["add", ".gitignore"], in: path)
        _ = try await run(["commit", "--quiet", "--message=Ignore"], in: path)
        let head = try await run(["rev-parse", "HEAD"], in: nested)
        _ = try await run(["update-index", "--add", "--cacheinfo", "160000,\(head),\(Self.brokenFolder)"], in: path)
        try FileManager.default.removeItem(atPath: nested + "/.git/objects")
        try FileManager.default.createDirectory(atPath: nested + "/.git/objects", withIntermediateDirectories: false)
        let session = try await RepositorySession.open(containing: path, git: git)
        let model = RepositoryModel(session: session, worktree: path, fetchesByItself: { false }, drafts: .none)
        return Worktree(model: model, path: path)
    }

    func setup() -> GenerationSetup {
        GenerationSetup(
            kind: .claude,
            agent: CommitMessageAgent(kind: .claude, executable: "/usr/local/bin/claude"),
            programs: Programs(searchPath: "/usr/bin"),
            style: "",
            matchesStyle: false,
            label: "Claude Code"
        )
    }

    final class Inputs: Sendable {
        let text = Mutex<String?>(nil)
    }

    /// An agent that answers with Claude Code's JSON around `reply`.
    func agent(_ reply: String, inputs: Inputs = Inputs(), delay: Duration = .zero) -> @Sendable (ProgramCommand, [UInt8]) async throws -> ProgramResult {
        { _, input in
            inputs.text.withLock { $0 = String(decoding: input, as: UTF8.self) }
            try await Task.sleep(for: delay)
            let json = #"{"type":"result","is_error":false,"result":\#(String(reflecting: reply))}"#
            return ProgramResult(status: .exited(0), output: Array(json.utf8), errorOutput: "", duration: .seconds(9))
        }
    }

    static let repair = "<why>The index has a gitlink for an ignored folder.</why><commands>\n[\"rm\", \"-r\", \"--cached\", \"-f\", \".build\"]\n</commands>"

    /// What git says in the broken worktree, from the command that says it.
    func refuse(_ work: Worktree) async throws -> String {
        do {
            _ = try await work.git("diff", "--name-only", "--no-renames", "HEAD", "--")
            Issue.record("git should have refused")
            return ""
        } catch {
            return error.dialogMessage
        }
    }

    func button(_ title: String, in dialog: DialogContent) throws -> DialogButton {
        try #require(dialog.buttons.first { $0.title == title })
    }

    // MARK: The offer

    @Test func aRefusalOffersTheAgentThatGenerateRuns() async throws {
        let work = try await broken()
        work.model.branch.failure = .init(title: "Can't pull main", message: "fatal: no", command: ["pull"])
        #expect(try work.offered(setup())?.title == "Fix with Claude")
        #expect(try work.offered(setup())?.kind == .secondary)
    }

    @Test func aCheckoutThatFailedOffersItToo() async throws {
        let work = try await broken()
        work.model.checkoutFailure = .init(branch: "main", message: "fatal: no", command: ["switch", "main"])
        #expect(try work.offered(setup())?.title == "Fix with Claude")
    }

    @Test func withoutAnAgentThereIsNothingToOffer() async throws {
        let work = try await broken()
        work.model.branch.failure = .init(title: "Can't pull main", message: "fatal: no", command: ["pull"])
        #expect(try work.offered(nil) == nil)
    }

    @Test func withoutACommandThereIsNothingToAskAbout() async throws {
        let work = try await broken()
        work.model.branch.failure = .init(title: "Can't pull main", message: "It went wrong.")
        #expect(try work.offered(setup()) == nil)
    }

    // MARK: The whole way through

    @Test func repairsARepositoryThatRefusesEverything() async throws {
        let work = try await broken()
        let said = try await refuse(work)
        #expect(said.contains("bad object HEAD"))
        work.model.branch.failure = .init(title: "Can't pull main", message: said, command: ["pull"], changedNothing: true)

        let inputs = Inputs()
        work.fix.runAgent = agent(Self.repair, inputs: inputs)
        try #require(try work.offered(setup())).action()
        #expect(work.model.branch.failure == nil)
        #expect(work.fix.dialog?.title == "Asking Claude Code…")

        let answer = try await work.settledDialog()
        #expect(answer.id == "gitFix-answer")
        #expect(answer.title == "What Claude suggests")
        #expect(answer.message?.plain == "The index has a gitlink for an ignored folder.")
        #expect(answer.terminal == [.command(["rm", "-r", "--cached", "-f", ".build"])])
        // Nothing has run: the worktree still refuses.
        #expect(try await refuse(work).contains("bad object HEAD"))

        let run = try button("Run", in: answer)
        #expect(run.kind == .primary)
        #expect(!run.pressesWithReturn)
        run.action()

        let done = try await work.settledDialog()
        #expect(done.id == "gitFix-finished")
        #expect(done.title == "The command ran")
        _ = try await work.git("diff", "--name-only", "--no-renames", "HEAD", "--")
        #expect(FileManager.default.fileExists(atPath: work.path + "/" + Self.brokenFolder + "/a.txt"))
        try button("OK", in: done).action()
        #expect(work.fix.dialog == nil)
    }

    @Test func gathersTheFactsThatExplainIt() async throws {
        let work = try await broken()
        let said = try await refuse(work)
        let inputs = Inputs()
        work.fix.runAgent = agent(Self.repair, inputs: inputs)
        work.fix.start(command: ["pull"], said: said, with: setup())
        await work.fix.work?.value
        let input = try #require(inputs.text.withLock { $0 })
        #expect(input.contains("status --porcelain=v1 --branch --ignore-submodules=all"))
        #expect(input.contains("--no-optional-locks"))
        // The gitlink, and that the folder is ignored even though it's in the index.
        #expect(input.contains("160000"))
        #expect(input.contains(".gitignore:1:.build/"))
    }

    // MARK: What it won't do

    @Test func aCommandItCantCheckOnlyShows() async throws {
        let work = try await broken()
        work.fix.runAgent = agent("<why>Set this.</why><commands>\n[\"config\", \"core.pager\", \"sh\"]\n</commands>")
        work.fix.start(command: ["pull"], said: "fatal: no", with: setup())
        let answer = try await work.settledDialog()
        #expect(answer.buttons.map(\.title) == ["OK"])
        #expect(answer.terminal == [.command(["config", "core.pager", "sh"])])
        #expect(answer.note?.plain.contains("Roga won't run git config core.pager sh") == true)
        work.fix.run()
        #expect(work.fix.dialog?.id == "gitFix-answer")
        #expect(try await work.git("config", "--get-all", "core.bare").isEmpty == false)
    }

    @Test func onePoisonedCommandMeansNoneRun() async throws {
        let work = try await broken()
        work.fix.runAgent = agent("<why>x</why><commands>\n[\"update-index\", \"--refresh\"]\n[\"submodule\", \"foreach\", \"sh\"]\n</commands>")
        work.fix.start(command: ["pull"], said: "fatal: no", with: setup())
        let answer = try await work.settledDialog()
        #expect(answer.buttons.map(\.title) == ["OK"])
    }

    @Test func aCommandThatCanLoseWorkIsRed() async throws {
        let work = try await broken()
        work.fix.runAgent = agent("<why>x</why><commands>\n[\"reset\", \"--hard\"]\n</commands>")
        work.fix.start(command: ["pull"], said: "fatal: no", with: setup())
        let answer = try await work.settledDialog()
        #expect(try button("Run", in: answer).kind == .destructive)
        #expect(answer.note?.plain.contains("can lose work") == true)
    }

    @Test func anAnswerWithNoCommandsOffersNothing() async throws {
        let work = try await broken()
        work.fix.runAgent = agent("<why>This does not explain it.</why><commands>\n</commands>")
        work.fix.start(command: ["pull"], said: "fatal: no", with: setup())
        let answer = try await work.settledDialog()
        #expect(answer.title == "Claude has no fix to suggest")
        #expect(answer.buttons.map(\.title) == ["OK"])
        #expect(answer.terminal.isEmpty)
    }

    @Test func theFirstFailureStopsTheRest() async throws {
        let work = try await broken()
        work.fix.runAgent = agent("<why>x</why><commands>\n[\"rm\", \"--cached\", \"nope\"]\n[\"rm\", \"-r\", \"--cached\", \"-f\", \".build\"]\n</commands>")
        work.fix.start(command: ["pull"], said: "fatal: no", with: setup())
        _ = try await work.settledDialog()
        work.fix.run()
        let done = try await work.settledDialog()
        #expect(done.title == "The commands stopped partway")
        #expect(done.message?.plain.contains("git rm --cached nope") == true)
        #expect(done.message?.plain.contains("The command after it didn't run.") == true)
        #expect(done.terminal.filter { if case .ran = $0 { true } else { false } }.count == 1)
        #expect(try await work.git("ls-files", "--stage").contains("160000"))
    }

    final class Replies: Sendable {
        let replies: Mutex<[String]>
        let inputs = Mutex<[String]>([])

        init(_ replies: [String]) {
            self.replies = Mutex(replies)
        }
    }

    /// An agent that gives each of `replies` in turn.
    func agent(replies: Replies) -> @Sendable (ProgramCommand, [UInt8]) async throws -> ProgramResult {
        { _, input in
            replies.inputs.withLock { $0.append(String(decoding: input, as: UTF8.self)) }
            let reply = replies.replies.withLock { $0.removeFirst() }
            let json = #"{"type":"result","is_error":false,"result":\#(String(reflecting: reply))}"#
            return ProgramResult(status: .exited(0), output: Array(json.utf8), errorOutput: "", duration: .seconds(9))
        }
    }

    /// What really happened the first time: git wants -f for a staged gitlink.
    @Test func askingAgainTellsTheAgentWhatGitSaidAboutItsFix() async throws {
        let work = try await broken()
        let without = "<why>x</why><commands>\n[\"rm\", \"--cached\", \"\(Self.brokenFolder)\"]\n</commands>"
        let replies = Replies([without, Self.repair])
        work.fix.runAgent = agent(replies: replies)
        work.fix.start(command: ["pull"], said: "fatal: no", with: setup())
        try button("Run", in: try await work.settledDialog()).action()

        let refused = try await work.settledDialog()
        #expect(refused.title == "git refused the command")
        #expect(refused.message?.plain.contains("after it") == false)
        try button("Fix with Claude", in: refused).action()
        #expect(work.fix.dialog?.id == "gitFix-asking")

        let answer = try await work.settledDialog()
        let second = try #require(replies.inputs.withLock { $0.last })
        #expect(second.contains("$ git rm --cached \(Self.brokenFolder)"))
        #expect(second.contains("use -f to force removal"))
        try button("Run", in: answer).action()

        let done = try await work.settledDialog()
        #expect(done.title == "The command ran")
        #expect(done.buttons.map(\.title) == ["OK"])
        _ = try await work.git("diff", "--name-only", "--no-renames", "HEAD", "--")
    }

    @Test func aReplyItCantReadSaysSo() async throws {
        let work = try await broken()
        work.fix.runAgent = agent("Try running git fsck.")
        work.fix.start(command: ["pull"], said: "fatal: no", with: setup())
        let failed = try await work.settledDialog()
        #expect(failed.id == "gitFix-failed")
        #expect(failed.title == "Claude Code couldn't suggest a fix")
        #expect(failed.terminal == [.output("Try running git fsck.")])
    }

    @Test func stoppingLeavesNothingBehind() async throws {
        let work = try await broken()
        work.fix.runAgent = agent(Self.repair, delay: .seconds(30))
        work.fix.start(command: ["pull"], said: "fatal: no", with: setup())
        let stop = try button("Stop", in: try #require(work.fix.dialog))
        stop.action()
        #expect(work.fix.dialog == nil)
        #expect(work.fix.work == nil)
    }
}
