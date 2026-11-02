/// Orders the commits reachable from a set of tips the way `git log` does
/// with `--date-order` or `--topo-order`, and hands them out a few at a time.
///
/// It follows git's incremental walk, so it gives the same order as git,
/// including between commits with the same time. A commit can't be handed out
/// until all of its children have been, so the walk has to know how many
/// children each commit has. Generation numbers tell it when it knows enough:
/// every child has a higher generation than its parents, so once every
/// commit at or above some generation has been counted, the children of the
/// commits below are all counted too. The walk only counts down as far as
/// the commits it's about to hand out, so the first screen of history needs
/// the commits near the top, not all of them.
///
/// git decides which tips are ready before it hands out anything, which
/// means counting down to the oldest tip first. With every tag of Linux as a
/// tip, that's most of its history. This waits until the walk reaches each
/// tip's place in the order instead, and gives the same order.
public struct HistoryOrder: Sendable {
    public enum Sort: Sendable {
        /// Newest first by commit time, but never a parent before all of its
        /// children, like `git log --date-order`.
        case date
        /// Each line of history kept together, like `git log --topo-order`,
        /// which `git log --graph` uses.
        case topological
    }

    public typealias Position = CommitGraph.Position

    public let graph: CommitGraph
    public let sort: Sort

    /// For each commit, what git calls its indegree: 0 until counting reaches
    /// it, and then one more than the number of its children that haven't
    /// been handed out. A commit is ready when this drops to 1, and is then
    /// marked `queued` until it's handed out, when it goes back to 0.
    private var pendingChildren: [Int32]
    /// The tips, newest first, and how many of them have been settled: put in
    /// the ready queue if nothing above them leads to them, or left for
    /// their children to make ready.
    private let tips: [Tip]
    private var settledTips = 0
    /// Whether each commit has been queued for counting.
    private var queuedForCounting: [Bool]
    /// Commits whose parents still have to be counted, highest generation first.
    private var counting = BinaryHeap<CountingEntry>()
    private var ready: ReadyQueue
    /// Every commit reachable from the tips with a generation at or above
    /// this one has been counted.
    private var countedDownTo = CommitGraph.infiniteGeneration
    /// The number of commits counted so far, which shows how far the walk
    /// has had to look.
    public private(set) var countedCommitsSoFar = 0

    /// Prepares to order the commits reachable from `tips`, which are
    /// positions in `graph`. Like git, it starts from the newest tip and
    /// ignores repeated ones.
    public init(graph: CommitGraph, tips: [Position], sort: Sort) throws(CommitGraphError) {
        self.graph = graph
        self.sort = sort
        pendingChildren = Array(repeating: 0, count: graph.count)
        queuedForCounting = Array(repeating: false, count: graph.count)

        // git sorts the tips by commit time with a stable sort, so tips with
        // the same time stay in the order they were given.
        var seen = Set<Position>()
        let unique = tips.filter { seen.insert($0).inserted }
        let times = unique.map(graph.commitTime(at:))
        let newestFirst = unique.indices.sorted { times[$0] != times[$1] ? times[$0] > times[$1] : $0 < $1 }

        var sortedTips: [Tip] = []
        for (arrival, index) in newestFirst.enumerated() {
            let tip = unique[index]
            let generation = try graph.generation(at: tip)
            queuedForCounting[Int(tip)] = true
            counting.push(CountingEntry(generation: generation, position: tip))
            pendingChildren[Int(tip)] = 1
            sortedTips.append(Tip(position: tip, time: times[index], arrival: UInt32(arrival), generation: generation))
        }
        self.tips = sortedTips
        // Tips that are ready come out ahead of commits with the same time
        // that become ready later, as they do in git.
        ready = ReadyQueue(sort: sort, firstArrival: UInt32(sortedTips.count))
        // Commits without generation numbers, such as ones newer than the
        // files, can't be counted a little at a time.
        try count(downTo: CommitGraph.infiniteGeneration)
    }

    /// Whether every commit has been handed out.
    public var isFinished: Bool { ready.isEmpty && settledTips == tips.count }

    /// Returns the next commit, or nil when there are no more.
    public mutating func next() throws(CommitGraphError) -> Position? {
        try settleTipsThatComeNext()
        guard let commit = ready.pop() else { return nil }
        pendingChildren[Int(commit)] = 0
        var index = 0
        while let parent = try graph.parent(of: commit, at: index) {
            index += 1
            // The parent's children have to be counted before it can be
            // known to be ready.
            let generation = try graph.generation(at: parent)
            if generation < countedDownTo {
                countedDownTo = generation
                try count(downTo: generation)
            }
            pendingChildren[Int(parent)] -= 1
            if pendingChildren[Int(parent)] == 1 {
                pendingChildren[Int(parent)] = Self.queued
                ready.push(parent, time: graph.commitTime(at: parent))
            }
        }
        return commit
    }

    /// Marks a commit that's in the ready queue.
    private static let queued: Int32 = -1

    /// Settles the tips that could come out before the commit at the front of
    /// the ready queue. git puts the ready tips in the queue first, so in
    /// topological order they're at the bottom of the stack, in the order of
    /// the tips, and come out only once it's empty above them. In date order
    /// they come out by time, ahead of later commits with the same time.
    private mutating func settleTipsThatComeNext() throws(CommitGraphError) {
        while settledTips < tips.count {
            let tip = tips[settledTips]
            switch sort {
            case .topological:
                guard ready.isEmpty else { return }
            case .date:
                if let front = ready.front, !ReadyEntry.comesBefore(tip.readyEntry, front) { return }
            }
            settledTips += 1
            // A tip is ready when no commit that leads to it has been
            // counted, once everything above its generation is.
            if tip.generation < countedDownTo {
                countedDownTo = tip.generation
                try count(downTo: tip.generation)
            }
            if pendingChildren[Int(tip.position)] == 1 {
                pendingChildren[Int(tip.position)] = Self.queued
                ready.push(tip.readyEntry)
            }
        }
    }

    /// Returns up to `count` commits, or fewer when there are no more.
    public mutating func next(_ count: Int) throws(CommitGraphError) -> [Position] {
        var rows: [Position] = []
        rows.reserveCapacity(min(count, graph.count))
        while rows.count < count, let commit = try next() {
            rows.append(commit)
        }
        return rows
    }

    /// Counts the children of every commit down to `cutoff`, by visiting
    /// commits from the highest generation down and counting each one's
    /// parents.
    private mutating func count(downTo cutoff: UInt64) throws(CommitGraphError) {
        while let top = counting.first, top.generation >= cutoff {
            counting.removeFirst()
            countedCommitsSoFar += 1
            var index = 0
            while let parent = try graph.parent(of: top.position, at: index) {
                index += 1
                let generation = try graph.generation(at: parent)
                // The walk is only right when generations go down from child
                // to parent. Newer commits have no generation of their own.
                if top.generation != CommitGraph.infiniteGeneration && generation >= top.generation {
                    throw .invalid(
                        path: graph.path(of: parent) ?? "",
                        reason: "Commit \(graph.id(at: parent)) has a generation number no lower than its child's."
                    )
                }
                let pending = pendingChildren[Int(parent)]
                pendingChildren[Int(parent)] = pending == 0 ? 2 : pending + 1
                if !queuedForCounting[Int(parent)] {
                    queuedForCounting[Int(parent)] = true
                    counting.push(CountingEntry(generation: generation, position: parent))
                }
            }
        }
    }
}

extension HistoryOrder {
    /// The commits that are ready to hand out. For date order they come out
    /// newest first, and in the order they arrived when their times are the
    /// same. For topological order the last one to arrive comes out first.
    private struct ReadyQueue: Sendable {
        let sort: Sort
        private var byDate = BinaryHeap<ReadyEntry>()
        private var stack: [Position] = []
        private var arrivals: UInt32

        /// Commits pushed by time get arrival numbers from `firstArrival` up,
        /// and the ones below are left for tips.
        init(sort: Sort, firstArrival: UInt32 = 0) {
            self.sort = sort
            arrivals = firstArrival
        }

        /// The commit that comes out next in date order.
        var front: ReadyEntry? { byDate.first }

        var isEmpty: Bool {
            switch sort {
            case .date: byDate.first == nil
            case .topological: stack.isEmpty
            }
        }

        mutating func push(_ position: Position, time: Int64) {
            push(ReadyEntry(time: time, arrival: arrivals, position: position))
            arrivals += 1
        }

        /// Pushes a commit with an arrival number it already has.
        mutating func push(_ entry: ReadyEntry) {
            switch sort {
            case .date: byDate.push(entry)
            case .topological: stack.append(entry.position)
            }
        }

        mutating func pop() -> Position? {
            switch sort {
            case .date: byDate.removeFirst()?.position
            case .topological: stack.popLast()
            }
        }
    }

    private struct Tip: Sendable {
        var position: Position
        var time: Int64
        /// The tip's place in the order of tips.
        var arrival: UInt32
        var generation: UInt64

        var readyEntry: ReadyEntry { ReadyEntry(time: time, arrival: arrival, position: position) }
    }

    private struct ReadyEntry: HeapElement {
        var time: Int64
        var arrival: UInt32
        var position: Position

        static func comesBefore(_ a: Self, _ b: Self) -> Bool {
            a.time != b.time ? a.time > b.time : a.arrival < b.arrival
        }
    }

    private struct CountingEntry: HeapElement {
        var generation: UInt64
        var position: Position

        static func comesBefore(_ a: Self, _ b: Self) -> Bool {
            a.generation > b.generation
        }
    }
}

protocol HeapElement: Sendable {
    /// Whether `a` should come out of the heap before `b`.
    static func comesBefore(_ a: Self, _ b: Self) -> Bool
}

/// A binary heap that hands out the element that comes first.
///
/// Ordering all of Linux pushes and removes 3 million elements, so the sifts
/// move a hole through the array instead of swapping, and work on the
/// array's buffer directly.
struct BinaryHeap<Element: HeapElement>: Sendable {
    private var elements: [Element] = []

    var first: Element? { elements.first }

    mutating func push(_ element: Element) {
        elements.append(element)
        elements.withUnsafeMutableBufferPointer { elements in
            var hole = elements.count - 1
            while hole > 0 {
                let parent = (hole - 1) / 2
                guard Element.comesBefore(element, elements[parent]) else { break }
                elements[hole] = elements[parent]
                hole = parent
            }
            elements[hole] = element
        }
    }

    @discardableResult
    mutating func removeFirst() -> Element? {
        guard let first = elements.first else { return nil }
        let last = elements.removeLast()
        guard !elements.isEmpty else { return first }
        elements.withUnsafeMutableBufferPointer { elements in
            let count = elements.count
            var hole = 0
            while true {
                var child = 2 * hole + 1
                guard child < count else { break }
                if child + 1 < count && Element.comesBefore(elements[child + 1], elements[child]) {
                    child += 1
                }
                guard Element.comesBefore(elements[child], last) else { break }
                elements[hole] = elements[child]
                hole = child
            }
            elements[hole] = last
        }
        return first
    }
}
