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
    /// been handed out. A commit is ready when this drops to 1.
    private var pendingChildren: [Int32]
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
        ready = ReadyQueue(sort: sort)

        // git sorts the tips by commit time with a stable sort, so tips with
        // the same time stay in the order they were given.
        var seen = Set<Position>()
        let unique = tips.filter { seen.insert($0).inserted }
        let times = unique.map(graph.commitTime(at:))
        let sorted = unique.indices
            .sorted { times[$0] != times[$1] ? times[$0] > times[$1] : $0 < $1 }
            .map { unique[$0] }

        for tip in sorted {
            let generation = try graph.generation(at: tip)
            queuedForCounting[Int(tip)] = true
            counting.push(CountingEntry(generation: generation, position: tip))
            countedDownTo = min(countedDownTo, generation)
            pendingChildren[Int(tip)] = 1
        }
        try count(downTo: countedDownTo)
        // A tip that's reachable from another tip waits for its children.
        for tip in sorted where pendingChildren[Int(tip)] == 1 {
            ready.push(tip, time: graph.commitTime(at: tip))
        }
        ready.startWithFirstPushed()
    }

    /// Whether every commit has been handed out.
    public var isFinished: Bool { ready.isEmpty }

    /// Returns the next commit, or nil when there are no more.
    public mutating func next() throws(CommitGraphError) -> Position? {
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
                ready.push(parent, time: graph.commitTime(at: parent))
            }
        }
        return commit
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
        private var arrivals: UInt32 = 0

        init(sort: Sort) {
            self.sort = sort
        }

        var isEmpty: Bool {
            switch sort {
            case .date: byDate.first == nil
            case .topological: stack.isEmpty
            }
        }

        mutating func push(_ position: Position, time: Int64) {
            switch sort {
            case .date:
                byDate.push(ReadyEntry(time: time, arrival: arrivals, position: position))
                arrivals += 1
            case .topological:
                stack.append(position)
            }
        }

        mutating func pop() -> Position? {
            switch sort {
            case .date: byDate.removeFirst()?.position
            case .topological: stack.popLast()
            }
        }

        /// Makes the commits pushed so far come out in the order they were
        /// pushed. git does this for the tips in topological order, so that
        /// the newest tip comes first.
        mutating func startWithFirstPushed() {
            if sort == .topological { stack.reverse() }
        }
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
