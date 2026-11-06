import Darwin
import Foundation
import Testing
@testable import AgentHooks

/// A made-up process tree, for walking up without starting processes.
private struct Tree {
    var entries: [pid_t: ProcessEntry] = [:]

    /// Processes from the helper's parent up, each one the parent of the
    /// one before.
    init(_ names: [String], topParent: pid_t = 500) {
        for (index, name) in names.enumerated() {
            let pid = pid_t(100 + index)
            let parent = index + 1 < names.count ? pid_t(101 + index) : topParent
            entries[pid] = ProcessEntry(pid: pid, parent: parent, name: name, start: Double(index))
        }
    }

    func find() -> ProcessEntry? {
        AgentProcess.find(above: 100) { entries[$0] }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AgentProcessTests {
    @Test func readsThisProcessFromTheKernel() throws {
        let entry = try #require(ProcessEntry(pid: getpid()))
        #expect(entry.pid == getpid())
        #expect(entry.parent == getppid())
        #expect(!entry.name.isEmpty)
        let now = Date().timeIntervalSince1970
        #expect(entry.start <= now)
        #expect(entry.start > now - 24 * 60 * 60)
        // The same process always gives the same start.
        #expect(ProcessEntry(pid: getpid())?.start == entry.start)
    }

    @Test func aProcessThatsGoneIsntThere() {
        #expect(ProcessEntry(pid: Int32.max) == nil)
        #expect(ProcessEntry(pid: 0) == nil)
        #expect(ProcessEntry(pid: -1) == nil)
    }

    @Test func findsTheProcessAboveTheTestProcess() throws {
        // The test process isn't a shell, so it's what it finds above itself.
        #expect(AgentProcess.find(above: getpid()) == ProcessEntry(pid: getpid()))

        // Above its parent it finds the first ancestor that isn't a shell.
        let found = try #require(AgentProcess.find(above: getppid()))
        #expect(!AgentProcess.wrappers.contains(found.name))
        var ancestors: [pid_t] = []
        var pid = getppid()
        while pid > 1, let entry = ProcessEntry(pid: pid), ancestors.count < 20 {
            ancestors.append(pid)
            pid = entry.parent
        }
        #expect(ancestors.contains(found.pid))
        #expect(ancestors.prefix { $0 != found.pid }.allSatisfy { ProcessEntry(pid: $0).map { AgentProcess.wrappers.contains($0.name) } ?? false })
    }

    @Test func skipsShellsAndWrappers() {
        // Codex runs a hook in a login shell, which runs the launcher, which
        // could run the helper through env.
        let tree = Tree(["roga-hook", "-zsh", "env", "codex", "zsh"])
        #expect(tree.find()?.name == "codex")
        #expect(tree.find()?.pid == 103)
        #expect(tree.find()?.start == 3)
        #expect(Tree(["2.1.286"]).find()?.pid == 100)
    }

    @Test func givesUpAfterEightWrappers() {
        let wrappers = ["sh", "bash", "zsh", "dash", "fish", "env", "login", "roga-hook"]
        #expect(Tree(wrappers + ["claude"]).find()?.name == "claude")
        #expect(Tree(["sh"] + wrappers + ["claude"]).find() == nil)
    }

    @Test func givesUpAtLaunchd() {
        // A hook whose agent has exited belongs to launchd.
        #expect(Tree(["sh", "zsh"], topParent: 1).find() == nil)
        #expect(AgentProcess.find(above: 1) == nil)
        #expect(AgentProcess.find(above: 0) == nil)
    }

    @Test func givesUpWhenAProcessOnTheWayIsGone() {
        #expect(Tree(["sh", "zsh"], topParent: 999).find() == nil)
    }
}
