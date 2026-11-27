import Foundation
import Testing
@testable import AgentHooks
@testable import RogaUI

/// What the branch row says about the agents in the worktree on screen
/// (decision 100), in two lines (decision 120): who and what state over what
/// they're doing, the mark or the light in the words, and the popover's
/// sections in their order.
struct AgentLineTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func agent(_ id: String, _ phase: AgentPhase, host: AgentHost = .claude, at seconds: Double = 0, _ activity: String? = nil) -> WorktreeAgent {
        WorktreeAgent(id: SessionKey(host: host, id: id), host: host, phase: phase, since: start.addingTimeInterval(seconds), activity: activity)
    }

    private func minutes(_ minutes: Double) -> Date {
        start.addingTimeInterval(minutes * 60 + 5)
    }

    @Test func nothingToSayLeavesTheRowAsItWas() {
        #expect(AgentLine([]) == nil)
        #expect(AgentLine([agent("a", .idle)]) == nil)
    }

    @Test func anAgentAtWorkSaysWhatItsDoingAndForHowLong() throws {
        let line = try #require(AgentLine([agent("a", .working, "Run the test suite"), agent("b", .idle)]))
        #expect(line.lines(now: minutes(6)) == ("Claude Code is working", "Claude Code", "6 min", "Run the test suite"))
        #expect(line.lines(now: start).time == nil)
        // The words shimmer rather than following a second ring under the
        // tab's.
        #expect(line.mark == nil)
        #expect(line.shimmers)
        #expect(!line.isWaiting)
        #expect(line.help(now: minutes(6)) == "Claude Code is working: Run the test suite, for 6 minutes")
        // The idle session has nothing to show in the popover either.
        #expect(line.agents.map(\.id.id) == ["a"])
    }

    @Test func anAgentThatHasntSaidAnythingIsNamed() throws {
        let line = try #require(AgentLine([agent("a", .working)]))
        #expect(line.lines(now: start) == ("Claude Code is working", "Claude Code", nil, nil))
    }

    @Test func anAgentThatWaitsIsInAmber() throws {
        let line = try #require(AgentLine([agent("a", .waiting(.permission), host: .codex, "git push")]))
        #expect(line.lines(now: minutes(2)) == ("Codex needs approval", "Codex", "2 min", "git push"))
        #expect(line.isWaiting)
        #expect(!line.shimmers)
        #expect(line.mark == .agent(.waiting(.permission)))
    }

    /// Two agents are named, and the one at work longest says what it's
    /// doing.
    @Test func severalSessionsAtWorkAreNamedOrCounted() throws {
        let line = try #require(AgentLine([agent("a", .working, at: 60, "Edit a.swift"), agent("b", .working, host: .codex, "Read b.swift")]))
        #expect(line.lines(now: minutes(6)) == ("Claude Code and Codex are working", "2 agents", "6 min", "Read b.swift"))
        let three = try #require(AgentLine([agent("a", .working), agent("b", .working), agent("c", .working, host: .codex)]))
        #expect(three.lines(now: start).state == "3 agents are working")
    }

    /// With another session doing something else, a bare "git push" wouldn't
    /// say which agent wants it.
    @Test func theOneThatWaitsIsNamedBesideOthers() throws {
        let line = try #require(AgentLine([
            agent("a", .working, "Run the test suite"),
            agent("b", .waiting(.permission), host: .codex, at: 120, "git push"),
            agent("c", .finished(failed: false), "Added the tooltip"),
        ]))
        // The second line says what the most urgent of the others is doing,
        // and in a narrow column the first counts them.
        #expect(line.lines(now: minutes(3)) == ("Codex needs approval", "Codex +2", "1 min", "git push · Claude Code is working"))
        #expect(line.isWaiting)
        // The line speaks for the one that waits, so its words don't shimmer
        // while Claude Code works.
        #expect(!line.shimmers)
        #expect(line.mark == .agent(.waiting(.permission)))
        #expect(line.agents.map(\.id.id) == ["b", "a", "c"])
    }

    @Test func aFinishedAgentShowsItsReplyAfterACheck() throws {
        let line = try #require(AgentLine([agent("a", .finished(failed: false), "Added the line to the tooltip")]))
        #expect(line.lines(now: minutes(30)) == ("Claude Code finished", "Claude Code", nil, "Added the line to the tooltip"))
        #expect(line.mark == .finished)
        #expect(!line.shimmers)
    }

    @Test func aTurnThatFailedSaysSo() throws {
        let line = try #require(AgentLine([agent("a", .finished(failed: true))]))
        #expect(line.hasFailed)
        #expect(line.mark == .failed)
        #expect(line.lines(now: minutes(5)) == ("Claude Code stopped with an error", "Claude Code", nil, "The agent's turn failed."))
        #expect(line.help(now: minutes(5)) == "Claude Code stopped with an error")
        // One that failed among others that finished is counted with them.
        let both = try #require(AgentLine([agent("a", .finished(failed: true)), agent("b", .finished(failed: false), host: .codex, "Done")]))
        #expect(!both.hasFailed)
        #expect(both.mark == .finished)
    }

    @Test func thePopoverListsTheMostUrgentFirstAndTheLongestAmongThem() throws {
        let line = try #require(AgentLine([
            agent("late", .working, at: 300),
            agent("done", .finished(failed: false)),
            agent("early", .working, at: 60),
            agent("asks", .waiting(.question), at: 400, "Wants a plan approved"),
        ]))
        #expect(line.agents.map(\.id.id) == ["asks", "early", "late", "done"])
    }

    @Test func eachSectionSaysWhatItsAgentIsDoing() {
        #expect(AgentLine.state(of: .working) == "Working")
        #expect(AgentLine.state(of: .waiting(.permission)) == "Approval required")
        #expect(AgentLine.state(of: .waiting(.question)) == "Waiting for you")
        #expect(AgentLine.state(of: .finished(failed: false)) == "Finished")
        #expect(AgentLine.state(of: .finished(failed: true)) == "Stopped with an error")
        #expect(AgentLine.mark(of: .finished(failed: true)) == .failed)
        #expect(AgentLine.mark(of: .waiting(.question)) == .agent(.waiting(.question)))

        let working = agent("a", .working, "Run the test suite")
        #expect(AgentLine.time(of: working, now: minutes(65)) == "1 hr 5 min")
        #expect(AgentLine.time(of: agent("b", .finished(failed: false)), now: minutes(65)) == nil)
        #expect(AgentLine.detail(of: working) == "Run the test suite")
        #expect(AgentLine.detail(of: agent("c", .finished(failed: true))) == "The agent's turn failed.")
    }

    /// The popover's times change as any agent working or waiting reaches
    /// another minute, and a finished one never moves them.
    @Test func thePopoverRedrawsForEveryAgentAtWork() throws {
        let line = try #require(AgentLine([agent("a", .working, at: 30), agent("b", .waiting(.question), at: 10), agent("c", .finished(failed: false))]))
        #expect(Set(line.minutes.since) == [start.addingTimeInterval(30), start.addingTimeInterval(10)])
    }
}
