import GitCore

/// Works out how a branch's history replays: which commits made up each
/// branch, the lane each branch takes, and when each commit lands.
///
/// git doesn't record which branch a commit was made on, so this is a guess
/// from the shape of the history and the merges' messages. It's only used for
/// the replay, and history everywhere else stays exactly what git says
/// (decision 62).
///
/// The main line runs back from the tip through each commit's first parent.
/// At a merge it follows the second parent instead when the message says
/// that's the branch being replayed, or when more pull requests landed on that
/// side, because pulling main into a branch and pushing the result puts main
/// second. Each merge on the main line then brings in a branch: the commits
/// behind its other parents that no earlier branch has claimed.
public struct HistoryReplay: Sendable {
    public typealias Position = CommitGraph.Position

    /// Which commits behind the tip to replay.
    public enum CommitRange: Sendable, Hashable {
        /// The whole history.
        case all
        /// The commits made at or after a time, in seconds since 1970, and
        /// any dated earlier that sit on top of those, as when someone's clock
        /// was wrong.
        case since(time: Int64)
        /// The commits that aren't behind another commit, such as a tag.
        case after(Position)
    }

    /// The text of a commit, which the repository's session loads.
    public struct Message: Sendable, Hashable {
        public var subject: String
        /// The first line of a merge's body, where GitHub puts the title of
        /// the pull request. Other commits can leave it empty.
        public var body: String

        public init(subject: String, body: String = "") {
            self.subject = subject
            self.body = body
        }
    }

    public struct Branch: Sendable, Hashable {
        public var name: String
        public var pullRequest: Int?
        public var title: String?
        /// 0 for the main line. Negative lanes are above it and positive ones
        /// below, and a lane's distance from 0 says how far.
        public var lane: Int
        /// Which of the graph's lane colors the branch takes.
        public var color: Int
        /// The branch's oldest commit, as an index into `commits`.
        public var first: Int
        /// The commit the branch left, or nil if it starts a history of its own.
        public var forkPoint: Int?
        /// The commit that merged it into the main line, or nil for the main line.
        public var merge: Int?
        /// The steps along the main line that the branch spans.
        public var start: Int
        public var end: Int
    }

    public struct Commit: Sendable, Hashable {
        public var id: ObjectID
        /// The commit's parents, as indexes into `commits`. They always come
        /// before the commit.
        public var parents: [Int]
        /// The committer date, in seconds since 1970.
        public var commitTime: Int64
        public var subject: String
        /// The commit's branch, as an index into `branches`. 0 is the main line.
        public var branch: Int
        /// The pull request a commit on the main line squashed, if it did.
        public var pullRequest: Int?
        /// Whether it's a merge on the main line.
        public var isMerge = false
        /// The branch a merge brought in.
        public var merged: Int?
        /// Whether it's the first commit of a branch.
        public var isFork = false
        /// Whether no branch is open here, so that the replay fast-forwards.
        public var isFast = false
        /// Which of the `stemCount` stems its subject flicks off on, when it's
        /// in a flat stretch and not too close to a merge's note.
        public var stem: Int?
        /// How many branches have started and merged, up to and including it.
        public var forksSoFar = 0
        public var mergesSoFar = 0
        /// When it lands, in seconds into the replay, fitted to the length.
        public internal(set) var time = 0.0
        /// When it lands before the replay is fitted to a length.
        var unfittedTime = 0.0
    }

    /// How many stems take turns through a flat stretch.
    public static let stemCount = 4

    /// Seconds between commits while a branch is open, and through quiet
    /// stretches of the main line.
    static let slowStep = 0.26
    static let fastStep = 0.07
    /// Extra pauses for a branch starting and a merge, so that they read.
    static let forkPause = 0.15
    static let mergePause = 0.3
    /// How long the replay waits before the first commit, and after the last.
    static let lead = 0.8
    static let tail = 0.5

    /// The name of the branch being replayed.
    public let mainLineName: String
    /// Every commit replayed, oldest first, each one after its parents. A
    /// commit's index here is how far along the line it's drawn.
    public private(set) var commits: [Commit]
    /// The branches. The first one is the main line, and the rest are in the
    /// order they merged.
    public let branches: [Branch]
    /// How far from the main line the farthest lane is.
    public let farthestLane: Int
    /// How much the length made the replay speed up, from 1 down.
    public private(set) var pace = 1.0
    /// When the last commit has landed and the replay is done playing.
    public private(set) var playEnd: Double
    private let unfittedEnd: Double

    /// Lists the commits in `range` behind `tip`, newest first, for loading
    /// their messages before making a replay.
    public static func commits(
        in graph: CommitGraph,
        from tip: Position,
        range: CommitRange
    ) throws(CommitGraphError) -> [Position] {
        var order = try HistoryOrder(graph: graph, tips: [tip], sort: .date)
        var commits: [Position] = []
        switch range {
        case .all:
            commits = try order.next(Int.max)
        case .since(let time):
            var (isInside, remaining) = try commitsSince(time, in: graph, from: tip)
            while remaining > 0, let commit = try order.next() {
                if isInside[Int(commit)] {
                    commits.append(commit)
                    remaining -= 1
                }
            }
        case .after(let base):
            var walk = SidesWalk(graph: graph)
            try walk.run(tip, base)
            var remaining = walk.visited.count(where: walk.isOnlyBehindFirst)
            while remaining > 0, let commit = try order.next() {
                if walk.isOnlyBehindFirst(commit) {
                    commits.append(commit)
                    remaining -= 1
                }
            }
        }
        return commits
    }

    /// Finds the commits in a range that starts at a time, by walking back
    /// from the tip and stopping at the commits outside it. Stopping once a
    /// few commits in a row look too old, as git does, loses newer commits
    /// behind them, and in Linux that cut the main line in half.
    private static func commitsSince(
        _ time: Int64,
        in graph: CommitGraph,
        from tip: Position
    ) throws(CommitGraphError) -> (isInside: [Bool], count: Int) {
        var isInside = [Bool](repeating: false, count: graph.count)
        var count = 0
        var stack = [tip]
        while let commit = stack.popLast() {
            if isInside[Int(commit)] { continue }
            guard try isInRange(commit, since: time, in: graph) else { continue }
            isInside[Int(commit)] = true
            count += 1
            var index = 0
            while let parent = try graph.parent(of: commit, at: index) {
                index += 1
                stack.append(parent)
            }
        }
        return (isInside, count)
    }

    /// Whether a commit was made at or after `time`, or says it was made
    /// earlier but has a parent that was made since. A corrected commit date
    /// is never lower than a parent's, so it shows that second case. Without
    /// one, a commit dated too early ends its line of the walk.
    private static func isInRange(
        _ commit: Position,
        since time: Int64,
        in graph: CommitGraph
    ) throws(CommitGraphError) -> Bool {
        if graph.commitTime(at: commit) >= time { return true }
        guard case .correctedCommitDates = graph.generations else { return false }
        let generation = try graph.generation(at: commit)
        return generation != CommitGraph.infiniteGeneration && generation >= UInt64(max(0, time))
    }

    /// Works out the replay of `positions`, which came from
    /// `commits(in:from:range:)`, with `messages` being their text in the same
    /// order. It plays for at most `length` seconds.
    public init(
        graph: CommitGraph,
        tip: Position,
        positions: [Position],
        messages: [Message],
        mainLineName: String,
        length: Double
    ) throws(CommitGraphError) {
        precondition(positions.count == messages.count, "Every commit needs its message")
        var builder = Builder(graph: graph, tip: tip, positions: positions, messages: messages, mainLineName: mainLineName)
        let replay = try builder.build()
        self.mainLineName = mainLineName
        commits = replay.commits
        branches = replay.branches
        farthestLane = replay.farthestLane
        unfittedEnd = replay.end
        playEnd = replay.end + Self.tail
        fit(to: length)
    }

    /// Speeds the replay up to fit `length` seconds, if it wouldn't otherwise.
    /// It never slows down.
    public mutating func fit(to length: Double) {
        pace = unfittedEnd > 0 ? min(1, length / unfittedEnd) : 1
        for index in commits.indices {
            commits[index].time = commits[index].unfittedTime * pace
        }
        playEnd = unfittedEnd * pace + Self.tail
    }
}

extension HistoryReplay {
    private struct Built {
        var commits: [Commit]
        var branches: [Branch]
        var farthestLane: Int
        var end: Double
    }

    /// The steps of working out a replay. Commits are numbered by their place
    /// in `positions` until the end, when they're renumbered from oldest to
    /// newest.
    private struct Builder {
        let graph: CommitGraph
        let tip: Position
        let positions: [Position]
        let messages: [Message]
        let mainLineName: String

        /// For each commit in the graph, its number here, or -1 if it's not replayed.
        var numbers: [Int32]
        var parents: [[Int32]] = []
        var times: [Int64] = []
        var landsPullRequest: [Bool] = []
        /// Whether each commit's first parent is outside the range.
        var lostFirstParent: [Bool] = []
        /// Whether at least one commit in twenty landed a pull request.
        var pullRequestsAreHowWorkLands = false
        var walk: SidesWalk
        /// Each commit's branch, or -1 until one claims it.
        var branchOf: [Int32]

        init(graph: CommitGraph, tip: Position, positions: [Position], messages: [Message], mainLineName: String) {
            self.graph = graph
            self.tip = tip
            self.positions = positions
            self.messages = messages
            self.mainLineName = MergeMessage.withoutOrigin(mainLineName)
            numbers = Array(repeating: -1, count: graph.count)
            walk = SidesWalk(graph: graph)
            branchOf = Array(repeating: -1, count: positions.count)
        }

        mutating func build() throws(CommitGraphError) -> Built {
            guard !positions.isEmpty else {
                return Built(commits: [], branches: [Self.mainLine(named: mainLineName, last: 0)], farthestLane: 0, end: 0)
            }
            for (number, position) in positions.enumerated() {
                numbers[Int(position)] = Int32(number)
            }
            try loadCommits()

            let order = oldestFirst()
            let (trunk, mainParents) = try followMainLine()
            var drafts = claimBranches(trunk: trunk, mainParents: mainParents)

            // A commit that nothing on the main line reaches stays off the replay.
            let shown = order.filter { branchOf[Int($0)] >= 0 }
            var steps = [Int32](repeating: -1, count: positions.count)
            for (step, commit) in shown.enumerated() { steps[Int(commit)] = Int32(step) }

            var branches = [Self.mainLine(named: mainLineName, last: shown.count - 1)]
            for draft in drafts.indices {
                let first = drafts[draft].commits.min { steps[Int($0)] < steps[Int($1)] }!
                let forkPoint = parents[Int(first)].first.map { Int(steps[Int($0)]) }
                drafts[draft].first = Int(steps[Int(first)])
                let merge = Int(steps[Int(drafts[draft].merge)])
                let message = drafts[draft].message
                // A merge that pulled the main line in names the main line,
                // not the branch it was made on.
                let name = message.name.flatMap { $0 == mainLineName ? nil : $0 }
                branches.append(Branch(
                    name: name ?? "branch",
                    pullRequest: message.pullRequest,
                    title: message.title,
                    lane: 0,
                    color: draft % 8,
                    first: Int(steps[Int(first)]),
                    forkPoint: forkPoint,
                    merge: merge,
                    start: forkPoint ?? Int(steps[Int(first)]),
                    end: merge
                ))
            }

            let farthestLane = Self.assignLanes(&branches)

            var commits: [Commit] = []
            commits.reserveCapacity(shown.count)
            for commit in shown {
                let number = Int(commit)
                let isOnMainLine = branchOf[number] == 0
                var replayed = Commit(
                    id: graph.id(at: positions[number]),
                    parents: parents[number].compactMap { steps[Int($0)] >= 0 ? Int(steps[Int($0)]) : nil },
                    commitTime: times[number],
                    subject: messages[number].subject,
                    branch: Int(branchOf[number])
                )
                if isOnMainLine { replayed.pullRequest = MergeMessage.squash(in: replayed.subject)?.number }
                // A commit at the edge of the range that still has a parent
                // inside it is bringing in a branch.
                if isOnMainLine && (parents[number].count > 1 || (lostFirstParent[number] && !parents[number].isEmpty)) {
                    replayed.isMerge = true
                    let other = parents[number].first { $0 != mainParents[number] }
                    replayed.merged = other.map { Int(branchOf[Int($0)]) }
                }
                replayed.isFork = !isOnMainLine && commits.count == branches[replayed.branch].first
                commits.append(replayed)
            }

            let end = Self.assignTimes(&commits, branches: branches)
            return Built(commits: commits, branches: branches, farthestLane: farthestLane, end: end)
        }

        static func mainLine(named name: String, last: Int) -> Branch {
            Branch(name: name, lane: 0, color: 0, first: 0, start: 0, end: last)
        }

        private mutating func loadCommits() throws(CommitGraphError) {
            parents.reserveCapacity(positions.count)
            times.reserveCapacity(positions.count)
            landsPullRequest.reserveCapacity(positions.count)
            var landed = 0
            for (number, position) in positions.enumerated() {
                var theirs: [Int32] = []
                var lost = false
                var index = 0
                while let parent = try graph.parent(of: position, at: index) {
                    let parentNumber = numbers[Int(parent)]
                    if parentNumber >= 0 {
                        theirs.append(parentNumber)
                    } else if index == 0 {
                        lost = true
                    }
                    index += 1
                }
                parents.append(theirs)
                lostFirstParent.append(lost)
                times.append(graph.commitTime(at: position))
                let lands = MergeMessage.landsPullRequest(messages[number].subject)
                landsPullRequest.append(lands)
                if lands { landed += 1 }
            }
            pullRequestsAreHowWorkLands = landed * 20 >= positions.count
        }

        /// A commit comes after all of its parents, and of the commits that
        /// are ready, the one with the earliest commit time goes next.
        private func oldestFirst() -> [Int32] {
            var waitingFor = parents.map { Int32($0.count) }
            var children = [[Int32]](repeating: [], count: positions.count)
            for child in parents.indices {
                for parent in parents[child] { children[Int(parent)].append(Int32(child)) }
            }
            var ready = BinaryHeap<OldestFirst>()
            for commit in parents.indices where parents[commit].isEmpty {
                ready.push(OldestFirst(time: times[commit], number: Int32(commit)))
            }
            var order: [Int32] = []
            order.reserveCapacity(positions.count)
            while let next = ready.removeFirst() {
                order.append(next.number)
                for child in children[Int(next.number)] {
                    waitingFor[Int(child)] -= 1
                    if waitingFor[Int(child)] == 0 {
                        ready.push(OldestFirst(time: times[Int(child)], number: child))
                    }
                }
            }
            return order
        }

        /// The commits of the main line, oldest first, and the parent each one
        /// follows.
        private mutating func followMainLine() throws(CommitGraphError) -> (trunk: [Int32], mainParents: [Int32]) {
            var mainParents = [Int32](repeating: -1, count: positions.count)
            var trunk: [Int32] = []
            var commit = numbers[Int(tip)]
            precondition(commit >= 0, "The tip has to be among the commits replayed")
            while commit >= 0 {
                let theirs = parents[Int(commit)]
                var next = theirs.first ?? -1
                if lostFirstParent[Int(commit)] {
                    // The main line starts at the edge of the range. Going on
                    // through another parent would leave it for a branch.
                    next = -1
                } else if theirs.count > 1 {
                    next = try mainParent(of: commit)
                }
                mainParents[Int(commit)] = next
                trunk.append(commit)
                branchOf[Int(commit)] = 0
                commit = next
            }
            trunk.reverse()
            return (trunk, mainParents)
        }

        /// Which of a merge's parents the main line continues through.
        private mutating func mainParent(of merge: Int32) throws(CommitGraphError) -> Int32 {
            let first = parents[Int(merge)][0]
            let second = parents[Int(merge)][1]
            if MergeMessage.namedBranch(in: messages[Int(merge)].subject) == mainLineName { return second }
            // Counting pull requests only means something where they're how
            // the work lands. Elsewhere, such as in Git's own history, topics
            // start from old commits, and walking both sides of every merge
            // takes far longer than anything else here.
            guard pullRequestsAreHowWorkLands else { return first }

            try walk.run(positions[Int(first)], positions[Int(second)], within: numbers)
            var onFirst = 0
            var onSecond = 0
            for position in walk.visited {
                let number = numbers[Int(position)]
                guard number >= 0, landsPullRequest[Int(number)] else { continue }
                if walk.isOnlyBehindFirst(position) { onFirst += 1 }
                if walk.isOnlyBehindSecond(position) { onSecond += 1 }
            }
            walk.reset()
            return onSecond > onFirst ? second : first
        }

        private struct DraftBranch {
            var commits: [Int32]
            var merge: Int32
            var message: MergeMessage
            var first = 0
        }

        /// Gives each merge on the main line the commits behind its other
        /// parents that no earlier branch has claimed.
        private mutating func claimBranches(trunk: [Int32], mainParents: [Int32]) -> [DraftBranch] {
            var drafts: [DraftBranch] = []
            var stack: [Int32] = []
            for merge in trunk {
                for parent in parents[Int(merge)] where parent != mainParents[Int(merge)] && branchOf[Int(parent)] < 0 {
                    let message = messages[Int(merge)]
                    var draft = DraftBranch(commits: [], merge: merge, message: MergeMessage(subject: message.subject, body: message.body))
                    let branch = Int32(drafts.count + 1)
                    stack.append(parent)
                    while let commit = stack.popLast() {
                        guard branchOf[Int(commit)] < 0 else { continue }
                        branchOf[Int(commit)] = branch
                        draft.commits.append(commit)
                        stack.append(contentsOf: parents[Int(commit)])
                    }
                    drafts.append(draft)
                }
            }
            return drafts
        }

        /// Lanes alternate above and below the main line, nearest first, and a
        /// lane is free again once its branch has merged. Returns how far the
        /// farthest lane is.
        private static func assignLanes(_ branches: inout [Branch]) -> Int {
            var freeAfter: [Int: Double] = [:]
            var farthest = 0
            let byStart = branches.indices.dropFirst().sorted {
                (branches[$0].start, $0) < (branches[$1].start, $1)
            }
            for index in byStart {
                var attempt = 0
                while true {
                    let lane = attempt % 2 == 0 ? -(attempt / 2 + 1) : (attempt + 1) / 2
                    if freeAfter[lane, default: -.infinity] < Double(branches[index].start) {
                        branches[index].lane = lane
                        freeAfter[lane] = Double(branches[index].end) + 1.5
                        farthest = max(farthest, abs(lane))
                        break
                    }
                    attempt += 1
                }
            }
            return farthest
        }

        /// Works out when each commit lands, before fitting a length, and
        /// returns when the last one has. Stretches with no branch open go
        /// faster.
        private static func assignTimes(_ commits: inout [Commit], branches: [Branch]) -> Double {
            var opening = [Int](repeating: 0, count: commits.count + 2)
            for branch in branches.dropFirst() {
                opening[branch.start] += 1
                opening[branch.end + 1] -= 1
            }
            var time = lead
            var open = 0
            var forks = 0
            var merges = 0
            var nextStem = 0
            var lastMerge = Int.min / 2
            for step in commits.indices {
                open += opening[step]
                commits[step].isFast = open == 0
                let isMerge = commits[step].isMerge
                let isFork = commits[step].isFork
                if isMerge { lastMerge = step }
                // The few commits right after a merge go without, so that
                // their subjects don't land on the merge's note.
                if commits[step].isFast && !isMerge && step - lastMerge > 4 {
                    commits[step].stem = nextStem % stemCount
                    nextStem += 1
                } else if !commits[step].isFast {
                    nextStem = 0
                }
                if isFork { time += forkPause }
                commits[step].unfittedTime = time
                time += commits[step].isFast ? fastStep : slowStep
                if isMerge { time += mergePause }
                if isFork { forks += 1 }
                if isMerge { merges += 1 }
                commits[step].forksSoFar = forks
                commits[step].mergesSoFar = merges
            }
            return time
        }
    }

    private struct OldestFirst: HeapElement {
        var time: Int64
        var number: Int32

        static func comesBefore(_ a: Self, _ b: Self) -> Bool {
            // Commits are numbered newest first, so the higher number is older.
            a.time != b.time ? a.time < b.time : a.number > b.number
        }
    }
}

/// Finds which commits are behind one of two commits but not the other.
///
/// It walks both at once from the highest generation down, marking what's
/// behind each. A commit's children all have higher generations, so by the
/// time the walk gets to one, it knows which sides it's on. It stops as soon
/// as everything left to visit is behind both, so it only visits the commits
/// back to where the two histories meet, the way git finds merge bases.
struct SidesWalk: Sendable {
    typealias Position = CommitGraph.Position

    private static let behindFirst: UInt8 = 1
    private static let behindSecond: UInt8 = 2
    private static let behindBoth: UInt8 = 3
    private static let queued: UInt8 = 4

    let graph: CommitGraph
    /// Every commit the walk visited.
    private(set) var visited: [Position] = []
    private var marks: [UInt8]
    private var queue = BinaryHeap<Entry>()
    /// How many commits in the queue aren't behind both yet.
    private var undecided = 0

    init(graph: CommitGraph) {
        self.graph = graph
        marks = Array(repeating: 0, count: graph.count)
    }

    func isOnlyBehindFirst(_ position: Position) -> Bool {
        marks[Int(position)] & Self.behindBoth == Self.behindFirst
    }

    func isOnlyBehindSecond(_ position: Position) -> Bool {
        marks[Int(position)] & Self.behindBoth == Self.behindSecond
    }

    /// Walks from two commits. With `numbers`, it stays among the commits that
    /// have a number of 0 or more.
    mutating func run(_ first: Position, _ second: Position, within numbers: [Int32]? = nil) throws(CommitGraphError) {
        try mark(first, Self.behindFirst)
        try mark(second, Self.behindSecond)
        while undecided > 0, let top = queue.removeFirst() {
            let position = top.position
            marks[Int(position)] &= ~Self.queued
            let sides = marks[Int(position)]
            if sides != Self.behindBoth { undecided -= 1 }
            var index = 0
            while let parent = try graph.parent(of: position, at: index) {
                index += 1
                if let numbers, numbers[Int(parent)] < 0 { continue }
                try mark(parent, sides)
            }
        }
        queue = BinaryHeap()
        undecided = 0
    }

    /// Forgets a walk, for making another. Clearing only what the walk
    /// touched keeps many short walks cheap in a large repository.
    mutating func reset() {
        for position in visited { marks[Int(position)] = 0 }
        visited.removeAll(keepingCapacity: true)
    }

    private mutating func mark(_ position: Position, _ sides: UInt8) throws(CommitGraphError) {
        let old = marks[Int(position)]
        let oldSides = old & Self.behindBoth
        let newSides = oldSides | sides
        if old == 0 { visited.append(position) }
        guard newSides != oldSides else { return }
        if old & Self.queued != 0 {
            if newSides == Self.behindBoth { undecided -= 1 }
            marks[Int(position)] = newSides | Self.queued
        } else {
            // A commit without a generation number can be reached again after
            // its turn, and goes back in the queue to pass on what's new.
            marks[Int(position)] = newSides | Self.queued
            if newSides != Self.behindBoth { undecided += 1 }
            queue.push(Entry(
                generation: try graph.generation(at: position),
                time: graph.commitTime(at: position),
                position: position
            ))
        }
    }

    private struct Entry: HeapElement {
        var generation: UInt64
        var time: Int64
        var position: Position

        static func comesBefore(_ a: Self, _ b: Self) -> Bool {
            if a.generation != b.generation { return a.generation > b.generation }
            return a.time != b.time ? a.time > b.time : a.position > b.position
        }
    }
}
