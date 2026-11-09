import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import CommitGraph

/// Works out the replay of a branch, with the commit text that git gives.
private func makeReplay(
    of ref: String,
    in repository: String,
    graph: CommitGraph,
    range: (CommitGraph) throws -> HistoryReplay.CommitRange = { _ in .all },
    length: Double = 10_000
) async throws -> HistoryReplay {
    let tip = try #require(graph.position(of: try await resolve([ref], in: repository)[0]))
    let positions = try HistoryReplay.commits(in: graph, from: tip, range: try range(graph))
    let messages = try await loadMessages(in: repository)
    return try HistoryReplay(
        graph: graph,
        tip: tip,
        positions: positions,
        messages: try positions.map { try #require(messages[graph.id(at: $0)]) },
        mainLineName: ref,
        length: length
    )
}

private func loadMessages(in repository: String) async throws -> [ObjectID: HistoryReplay.Message] {
    let git = try await TestGit.make()
    let text = try await git.text(GitCommand("log", "--all", "--format=%H%x1f%s%x1f%b%x1e", in: repository))
    var messages: [ObjectID: HistoryReplay.Message] = [:]
    for record in text.split(separator: "\u{1e}") {
        let fields = record.drop { $0.isNewline }.split(separator: "\u{1f}", omittingEmptySubsequences: false)
        guard fields.count == 3 else { continue }
        let id = try #require(ObjectID(hex: fields[0]))
        let body = fields[2].drop { $0.isNewline }.prefix { !$0.isNewline }
        messages[id] = HistoryReplay.Message(subject: String(fields[1]), body: String(body))
    }
    return messages
}

private func revList(_ arguments: String..., in repository: String) async throws -> Set<ObjectID> {
    let git = try await TestGit.make()
    let text = try await git.text(GitCommand(["rev-list"] + arguments, in: repository))
    return Set(try text.split(separator: "\n").map { try #require(ObjectID(hex: $0)) })
}

private func openGraph(_ repository: String) throws -> CommitGraph {
    try #require(try CommitGraph(objectsFolder: repository + "/.git/objects", format: .sha1))
}

/// A straight line of commits made at these times, in hours from midnight on
/// 2026-01-01 in UTC.
private func straightLine(atHours hours: [Double]) throws -> HistoryReplay {
    var newer: [CommitGraph.NewerCommit] = []
    var messages: [ObjectID: HistoryReplay.Message] = [:]
    for (index, hour) in hours.enumerated() {
        let id = try #require(ObjectID(hex: String(format: "%040x", index + 1)))
        newer.append(CommitGraph.NewerCommit(id: id, parents: newer.last.map { [$0.id] } ?? [], commitTime: 1_767_225_600 + Int64(hour * 3600)))
        messages[id] = HistoryReplay.Message(subject: "Commit \(index)")
    }
    let graph = try CommitGraph(format: .sha1).adding(newer)
    let last = try #require(newer.last)
    let tip = try #require(graph.position(of: last.id))
    let positions = try HistoryReplay.commits(in: graph, from: tip, range: .all)
    return try HistoryReplay(
        graph: graph,
        tip: tip,
        positions: positions,
        messages: positions.map { messages[graph.id(at: $0)]! },
        mainLineName: "main",
        length: 10_000
    )
}

@Suite(.timeLimit(.minutes(1)))
struct ReplayHighlightsTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func findsTheDaysAndTheBusiestOne() throws {
        let highlights = try straightLine(atHours: [10, 23.5, 27.6, 33, 36, 64]).highlights(in: utc)
        #expect(highlights.days.map(\.commits) == [2, 3, 1])
        #expect(highlights.days.map(\.first) == [0, 2, 5])
        #expect(highlights.days.map(\.number) == [1, 2, 3])
        #expect(highlights.days[1].last == 4)
        #expect(highlights.dayCount == 3)
        #expect(highlights.busiestDay == 1)
    }

    @Test func countsDaysWithoutACommit() throws {
        let highlights = try straightLine(atHours: [10, 11, 80]).highlights(in: utc)
        #expect(highlights.days.map(\.number) == [1, 4])
        #expect(highlights.dayCount == 4)
    }

    /// 3:36 in the morning belongs to the evening before.
    @Test func findsTheLatestCommitPastMidnight() throws {
        let highlights = try straightLine(atHours: [10, 23.5, 27.6, 33]).highlights(in: utc)
        #expect(highlights.latestCommit == 2)
        #expect(highlights.latestIsAtNight)
        #expect(highlights.commitsByHour[3] == 1)
        #expect(highlights.commitsByHour[10] == 1)
    }

    @Test func saysWhenTheLatestCommitWasNotAtNight() throws {
        let highlights = try straightLine(atHours: [9, 12, 18.25]).highlights(in: utc)
        #expect(highlights.latestCommit == 2)
        #expect(!highlights.latestIsAtNight)
    }

    @Test func findsTheBiggestCommitOnceTheLinesAreCounted() throws {
        var replay = try straightLine(atHours: [1, 2, 3])
        #expect(replay.highlights(in: utc).biggestCommit == nil)
        replay.countLines([
            replay.commits[0].id: .init(added: 5, removed: 1),
            replay.commits[1].id: .init(added: 10, removed: 90),
            replay.commits[2].id: .init(added: 80, removed: 0),
        ])
        #expect(replay.highlights(in: utc).biggestCommit == 1)
    }

    @Test func findsTheLongestBranch() async throws {
        let repository = try await Fixture.repository("replay")
        let replay = try await makeReplay(of: "main", in: repository, graph: try openGraph(repository))
        let highlights = replay.highlights(in: utc)
        let branch = try #require(highlights.longestBranch)
        #expect(branch != 0)
        let counts = replay.branches.indices.map { index in replay.commits.count { $0.branch == index } }
        #expect(highlights.longestBranchCommits == counts.dropFirst().max())
        #expect(counts[branch] == highlights.longestBranchCommits)
    }

    @Test func pointsOutNothingThatDoesNotStandOut() throws {
        let highlights = try straightLine(atHours: [1]).highlights(in: utc)
        #expect(highlights.busiestDay == nil)
        #expect(highlights.biggestCommit == nil)
        #expect(highlights.longestBranch == nil)
        #expect(highlights.dayCount == 1)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct HistoryReplayTests {
    private func replay() async throws -> HistoryReplay {
        let repository = try await Fixture.repository("replay")
        return try await makeReplay(of: "main", in: repository, graph: try openGraph(repository))
    }

    @Test func followsTheMainLineThroughEveryKindOfMerge() async throws {
        let replay = try await replay()
        let mainLine = replay.commits.filter { $0.branch == 0 }.map(\.subject)
        #expect(mainLine == [
            "Initial commit", "Add the readme", "Add a license", "Add the build script", "Add the tests",
            "Set up CI", "Add the docs", "Tidy the config", "Merge pull request #1 from ana/add-login",
            "Bump the version", "Merge pull request #2 from ana/refactor", "Fix the header (#3)",
            "Merge branch 'search' into 'main'", "Merged in export (pull request #12)", "Update the changelog",
            "Merge branch 'main' of github.com:ana/app", "Merge pull request #4 from ana/avatars",
            "Add themes (#5)", "Sync the layout work", "Release 1.0",
        ])
    }

    @Test func namesBranchesFromTheirMerges() async throws {
        let branches = try await replay().branches
        #expect(branches.map(\.name) == ["main", "add-login", "refactor", "search", "export", "branch", "avatars", "branch"])
        #expect(branches.map(\.pullRequest) == [nil, 1, 2, nil, 12, nil, 4, nil])
        #expect(branches[1].title == "Add a login page")
        #expect(branches[2].title == "Refactor the router")
        #expect(branches[6].title == "Show avatars")
    }

    /// The back-merge stays on its branch, and main's commit behind it stays
    /// on the main line.
    @Test func keepsABackMergeOnItsBranch() async throws {
        let replay = try await replay()
        let refactor = replay.commits.filter { $0.branch == 2 }.map(\.subject)
        #expect(refactor == ["Split the router", "Merge branch 'main' into refactor", "Finish the router"])
        let bump = try #require(replay.commits.first { $0.subject == "Bump the version" })
        #expect(bump.branch == 0)
    }

    /// Each foxtrot leaves the work done on the side as a short branch,
    /// instead of treating all of main as one.
    @Test func keepsTheMainLineThroughFoxtrotMerges() async throws {
        let replay = try await replay()
        #expect(replay.commits.filter { $0.branch == 5 }.map(\.subject) == ["Work on the sidebar"])
        #expect(replay.commits.filter { $0.branch == 7 }.map(\.subject) == ["Try a new layout", "Polish the layout"])
    }

    @Test func marksMergesForksAndSquashes() async throws {
        let replay = try await replay()
        let pr1 = try #require(replay.commits.first { $0.subject.hasPrefix("Merge pull request #1") })
        #expect(pr1.isMerge)
        #expect(pr1.merged == 1)
        let squash = try #require(replay.commits.first { $0.subject == "Fix the header (#3)" })
        #expect(squash.pullRequest == 3)
        #expect(!squash.isMerge)
        let forks = replay.commits.filter(\.isFork).map(\.subject)
        #expect(forks.count == replay.branches.count - 1)
        #expect(forks.contains("Start the login page"))
        #expect(replay.commits.last?.forksSoFar == 7)
        #expect(replay.commits.last?.mergesSoFar == 7)
    }

    @Test func placesBranchesInLanesNearestFirst() async throws {
        let replay = try await replay()
        #expect(replay.branches[0].lane == 0)
        #expect(replay.branches[1].lane == -1)
        // Two branches can't share a lane while both are open.
        let branches = replay.branches.dropFirst()
        for a in branches {
            for b in branches where a != b && a.lane == b.lane {
                #expect(Double(a.end) + 1.5 < Double(b.start) || Double(b.end) + 1.5 < Double(a.start))
            }
        }
        #expect(replay.farthestLane == branches.map { abs($0.lane) }.max())
        #expect(replay.farthestLane >= 1)
    }

    @Test func leavesTimeToReadAFlatStretch() async throws {
        let replay = try await replay()
        #expect(abs(replay.commits[1].time - replay.commits[0].time - HistoryReplay.flatStep) < 1e-9)
    }

    @Test func givesASquashedPullRequestAsLongAsAMerge() async throws {
        let repository = try await Fixture.repository("replay")
        let replay = try await makeReplay(of: "squashes", in: repository, graph: try openGraph(repository))
        #expect(abs(replay.commits[1].time - replay.commits[0].time - HistoryReplay.flatStep - HistoryReplay.mergePause) < 1e-9)
    }

    @Test func landsCommitsInOrderWithPausesForForksAndMerges() async throws {
        let replay = try await replay()
        for (older, newer) in zip(replay.commits, replay.commits.dropFirst()) {
            #expect(older.time < newer.time)
        }
        #expect(replay.commits[0].time == HistoryReplay.lead)
        #expect(replay.playEnd > replay.commits.last!.time)
    }

    @Test func fitsALengthWithoutEverSlowingDown() async throws {
        var replay = try await replay()
        let natural = replay.playEnd
        let lastTime = replay.commits.last!.time
        #expect(replay.pace == 1)

        replay.fit(to: 2)
        #expect(replay.pace < 1)
        #expect(abs(replay.playEnd - (2 + HistoryReplay.tail)) < 1e-9)
        #expect(replay.commits.last!.time < 2)

        replay.fit(to: 10_000)
        #expect(replay.pace == 1)
        #expect(replay.playEnd == natural)
        #expect(replay.commits.last!.time == lastTime)
    }

    @Test func aRepositoryOfSquashesIsAStraightLineOfInterchanges() async throws {
        let repository = try await Fixture.repository("replay")
        let replay = try await makeReplay(of: "squashes", in: repository, graph: try openGraph(repository))
        #expect(replay.branches.count == 1)
        #expect(replay.commits.map(\.pullRequest) == [1, 2, 3])
        #expect(replay.farthestLane == 0)
    }

    @Test func replaysOnlyTheRangeAfterATag() async throws {
        let repository = try await Fixture.repository("replay")
        let graph = try openGraph(repository)
        let base = try #require(graph.position(of: try await resolve(["flat"], in: repository)[0]))
        let replay = try await makeReplay(of: "main", in: repository, graph: graph, range: { _ in .after(base) })
        #expect(Set(replay.commits.map(\.id)) == (try await revList("flat..main", in: repository)))
        // The commits after the tag have lost their parent there.
        #expect(replay.commits[0].parents.isEmpty)
    }

    @Test func replaysOnlyTheRangeSinceATime() async throws {
        let repository = try await Fixture.repository("replay")
        let graph = try openGraph(repository)
        // Fifteen hours in: the second pull request's merge and onward.
        let time: Int64 = 1_767_225_600 + 15 * 3600
        let replay = try await makeReplay(of: "main", in: repository, graph: graph, range: { _ in .since(time: time) })
        #expect(Set(replay.commits.map(\.id)) == (try await revList("--since=\(time)", "main", in: repository)))
    }

    /// 1,050 hours after the fixture starts, which is after its old commits
    /// and before its recent ones.
    private static let cutoff: Int64 = 1_767_225_600 + 1050 * 3600

    /// Six commits in a row with an old date used to end the walk, and lost
    /// the recent commit underneath them.
    @Test func keepsTheCommitsBehindOnesWithAnOldClock() async throws {
        let repository = try await Fixture.repository("replay")
        let graph = try openGraph(repository)
        let replay = try await makeReplay(of: "skewed", in: repository, graph: graph, range: { _ in .since(time: Self.cutoff) })
        #expect(replay.commits.filter { $0.branch == 0 }.map(\.subject) == [
            "Recent base", "Recent follow-up", "Merge branch 'old-clock'",
        ])
        #expect(replay.commits.count == 9)
        #expect(!replay.commits.contains { $0.subject == "Older work" })
        #expect(replay.commits.last?.mergesSoFar == 1)
    }

    /// Without corrected commit dates, the old commits can't be told from
    /// ones outside the range, but the recent commit is still found.
    @Test func keepsTheMainLineWithoutCorrectedCommitDates() async throws {
        let repository = try await Fixture.repository("replay")
        var graph = try openGraph(repository)
        graph.generations = .none
        let replay = try await makeReplay(of: "skewed", in: repository, graph: graph, range: { _ in .since(time: Self.cutoff) })
        #expect(replay.commits.map(\.subject) == ["Recent base", "Recent follow-up", "Merge branch 'old-clock'"])
    }

    /// A merge at the edge of the range starts the main line, and what it
    /// brought in is a branch.
    @Test func endsTheMainLineWhereItsFirstParentLeavesTheRange() async throws {
        let repository = try await Fixture.repository("replay")
        let graph = try openGraph(repository)
        let replay = try await makeReplay(of: "lost", in: repository, graph: graph, range: { _ in .since(time: Self.cutoff) })
        #expect(replay.commits.filter { $0.branch == 0 }.map(\.subject) == ["Merge branch 'side'", "After the merge"])
        #expect(replay.commits.filter { $0.branch == 1 }.map(\.subject) == ["Side work", "More side work"])
        #expect(replay.branches.map(\.name) == ["lost", "side"])
        let merge = try #require(replay.commits.first { $0.subject == "Merge branch 'side'" })
        #expect(merge.isMerge)
        #expect(merge.merged == 1)
    }

    @Test func replaysNothingForAnEmptyRange() async throws {
        let repository = try await Fixture.repository("replay")
        let graph = try openGraph(repository)
        let replay = try await makeReplay(of: "main", in: repository, graph: graph, range: { _ in .since(time: 4_000_000_000) })
        #expect(replay.commits.isEmpty)
        #expect(replay.branches.count == 1)
    }

    /// The `history` repositories have an octopus merge, a merged-in root,
    /// commits with the same time, and dates out of order.
    @Test(arguments: Fixture.History.allCases)
    func replaysEveryCommitOnceWithParentsFirst(_ history: Fixture.History) async throws {
        let repository = try await history.repository()
        let graph = try await history.graph()
        let replay = try await makeReplay(of: "main", in: repository, graph: graph)

        #expect(Set(replay.commits.map(\.id)) == (try await revList("main", in: repository)))
        #expect(replay.commits.count == Set(replay.commits.map(\.id)).count)
        for (step, commit) in replay.commits.enumerated() {
            #expect(commit.parents.allSatisfy { $0 < step })
        }
        let octopus = try #require(replay.commits.first { $0.subject == "Merge topics B, C and D" })
        #expect(octopus.isMerge)
        #expect(replay.branches.filter { $0.merge == replay.commits.firstIndex(of: octopus) }.count == 3)
        // The merged-in root started a history of its own.
        let pages = try #require(replay.branches.first { branch in
            replay.commits[branch.first].subject == "Pages 1"
        })
        #expect(pages.forkPoint == nil)
    }

    /// Without generation numbers, the walks go by commit time and find the
    /// same main line.
    @Test func worksOutTheSameWithoutGenerationNumbers() async throws {
        let repository = try await Fixture.repository("replay")
        var graph = try openGraph(repository)
        let with = try await makeReplay(of: "main", in: repository, graph: graph)
        graph.generations = .none
        let without = try await makeReplay(of: "main", in: repository, graph: graph)
        #expect(with.commits == without.commits)
        #expect(with.branches == without.branches)
    }

    /// The walk stops where the two sides meet, however much history is below.
    @Test func comparesSidesWithoutWalkingAllOfHistory() async throws {
        let repository = try await Fixture.History.single.repository()
        let graph = try await Fixture.History.single.graph()
        let (a, b) = try await {
            let tips = try await resolve(["topic-a", "main~8"], in: repository)
            return (try #require(graph.position(of: tips[0])), try #require(graph.position(of: tips[1])))
        }()
        var walk = SidesWalk(graph: graph)
        try walk.run(a, b)
        #expect(walk.visited.count < 20)
        let onlyA = walk.visited.filter(walk.isOnlyBehindFirst).map(graph.id(at:))
        #expect(Set(onlyA) == (try await revList("topic-a", "^main~8", in: repository)))
        let onlyB = walk.visited.filter(walk.isOnlyBehindSecond).map(graph.id(at:))
        #expect(Set(onlyB) == (try await revList("main~8", "^topic-a", in: repository)))
    }

    @Test func addsUpTheLinesOfEachCommitOnceTheyreCounted() async throws {
        var replay = try await replay()
        #expect(!replay.hasLineCounts)
        #expect(replay.commits.allSatisfy { $0.linesSoFar == .init(added: 0, removed: 0) })

        let merge = try #require(replay.commits.firstIndex { $0.isMerge })
        replay.countLines([
            replay.commits[0].id: .init(added: 10, removed: 0),
            replay.commits[3].id: .init(added: 5, removed: 2),
            replay.commits[merge + 1].id: .init(added: 1, removed: 7),
        ])
        #expect(replay.hasLineCounts)
        #expect(replay.commits[0].lines == .init(added: 10, removed: 0))
        #expect(replay.commits[1].lines == .init(added: 0, removed: 0))
        #expect(replay.commits[2].linesSoFar == .init(added: 10, removed: 0))
        #expect(replay.commits[3].linesSoFar == .init(added: 15, removed: 2))
        #expect(replay.commits[merge].lines == .init(added: 0, removed: 0))
        #expect(replay.commits.last?.linesSoFar == .init(added: 16, removed: 9))

        // Fitting another length keeps them.
        replay.fit(to: 20)
        #expect(replay.commits.last?.linesSoFar == .init(added: 16, removed: 9))
    }

    @Test func readsTheForgesMergeMessages() {
        let github = MergeMessage(subject: "Merge pull request #52 from tmarkovski/tm/first-release", body: "Ship it")
        #expect(github == MergeMessage(name: "tm/first-release", pullRequest: 52, title: "Ship it"))

        #expect(MergeMessage(subject: "Merged in fix/thing (pull request #12)", body: "").name == "fix/thing")
        #expect(MergeMessage(subject: "Merged in fix/thing (pull request #12)", body: "").pullRequest == 12)
        #expect(MergeMessage(subject: "Merged in fix/thing", body: "").pullRequest == nil)
        #expect(MergeMessage(subject: "Merge branch 'x' into 'main'", body: "").name == "x")
        #expect(MergeMessage(subject: "Merge remote-tracking branch 'origin/x'", body: "").name == "x")

        let squash = MergeMessage(subject: "Add themes (#5)", body: "")
        #expect(squash.pullRequest == 5)
        #expect(squash.title == "Add themes")
        #expect(squash.name == nil)

        #expect(MergeMessage(subject: "Nothing to see (issue #5)", body: "").pullRequest == nil)
        #expect(MergeMessage(subject: "Merge pull request #52 from nowhere", body: "").pullRequest == nil)
    }

    @Test func recognizesCommitsThatLandPullRequests() {
        #expect(MergeMessage.landsPullRequest("Merge pull request #1 from a/b"))
        #expect(MergeMessage.landsPullRequest("Add themes (#5)"))
        #expect(!MergeMessage.landsPullRequest("Merge pull request from a/b"))
        #expect(!MergeMessage.landsPullRequest("Add themes (see #5)"))
        #expect(!MergeMessage.landsPullRequest("Add themes"))
    }
}

extension MergeMessage {
    init(name: String?, pullRequest: Int?, title: String?) {
        self.init(subject: "", body: "")
        self.name = name
        self.pullRequest = pullRequest
        self.title = title
    }
}
