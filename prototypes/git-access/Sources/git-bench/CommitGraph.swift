import Foundation

/// Reads a single-file commit-graph (`objects/info/commit-graph`) by mapping it into memory.
/// See https://git-scm.com/docs/gitformat-commit-graph for the format.
///
/// The prototype doesn't handle split commit-graph chains (`objects/info/commit-graphs/`).
final class CommitGraph {
    let count: Int
    private let base: UnsafeRawPointer
    private let size: Int
    private let fanout: Int
    private let lookup: Int
    private let data: Int
    private let edges: Int?

    private static let parentNone: UInt32 = 0x7000_0000
    private static let entrySize = 36

    init(path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            throw BenchError("No commit-graph at \(path). Run `git commit-graph write --reachable` first.")
        }
        defer { close(fd) }
        var info = stat()
        fstat(fd, &info)
        let size = Int(info.st_size)
        guard let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != UnsafeMutableRawPointer(bitPattern: -1) else {
            throw BenchError("Couldn't map \(path)")
        }
        let base = UnsafeRawPointer(mapped)

        func be32(_ offset: Int) -> UInt32 { UInt32(bigEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        func be64(_ offset: Int) -> UInt64 { UInt64(bigEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }

        guard size > 8, be32(0) == 0x4347_5048 /* CGPH */,
              base.load(fromByteOffset: 4, as: UInt8.self) == 1,
              base.load(fromByteOffset: 5, as: UInt8.self) == 1 /* SHA-1 */ else {
            munmap(mapped, size)
            throw BenchError("\(path) isn't a version 1 SHA-1 commit-graph")
        }
        guard base.load(fromByteOffset: 7, as: UInt8.self) == 0 else {
            munmap(mapped, size)
            throw BenchError("\(path) is part of a split commit-graph chain, which the prototype doesn't read")
        }

        var chunks: [UInt32: Int] = [:]
        let chunkCount = Int(base.load(fromByteOffset: 6, as: UInt8.self))
        for i in 0..<chunkCount {
            chunks[be32(8 + i * 12)] = Int(be64(8 + i * 12 + 4))
        }
        guard let fanout = chunks[0x4F49_4446 /* OIDF */],
              let lookup = chunks[0x4F49_444C /* OIDL */],
              let data = chunks[0x4344_4154 /* CDAT */] else {
            munmap(mapped, size)
            throw BenchError("\(path) is missing a required chunk")
        }

        self.base = base
        self.size = size
        self.fanout = fanout
        self.lookup = lookup
        self.data = data
        self.edges = chunks[0x4544_4745 /* EDGE */]
        self.count = Int(be32(fanout + 255 * 4))
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), size) }

    @inline(__always)
    private func be32(_ offset: Int) -> UInt32 {
        UInt32(bigEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    func oidBytes(_ position: Int32) -> UnsafeRawPointer { base + lookup + Int(position) * 20 }

    func oid(_ position: Int32) -> OID { OID(raw: oidBytes(position)) }

    func commitTime(_ position: Int32) -> Int64 {
        let entry = data + Int(position) * Self.entrySize
        return Int64(be32(entry + 28) & 0x3) << 32 | Int64(be32(entry + 32))
    }

    /// Appends the graph positions of a commit's parents.
    func parents(of position: Int32, into out: inout [Int32]) {
        let entry = data + Int(position) * Self.entrySize
        let first = be32(entry + 20)
        let second = be32(entry + 24)
        if first != Self.parentNone { out.append(Int32(first)) }
        if second == Self.parentNone { return }
        if second & 0x8000_0000 == 0 {
            out.append(Int32(second))
            return
        }
        guard let edges else { return }
        var k = Int(second & 0x7FFF_FFFF)
        while true {
            let edge = be32(edges + k * 4)
            out.append(Int32(edge & 0x7FFF_FFFF))
            if edge & 0x8000_0000 != 0 { break }
            k += 1
        }
    }

    /// Finds a commit's position by binary search, using the fanout table to narrow the range.
    func position(of oid: OID) -> Int32? {
        var raw = (oid.w0.bigEndian, oid.w1.bigEndian, oid.w2.bigEndian)
        return withUnsafeBytes(of: &raw) { key -> Int32? in
            let firstByte = Int(key.load(as: UInt8.self))
            var low = firstByte == 0 ? 0 : Int(be32(fanout + (firstByte - 1) * 4))
            var high = Int(be32(fanout + firstByte * 4))
            while low < high {
                let middle = (low + high) / 2
                let comparison = memcmp(oidBytes(Int32(middle)), key.baseAddress!, 20)
                if comparison == 0 { return Int32(middle) }
                if comparison < 0 { low = middle + 1 } else { high = middle }
            }
            return nil
        }
    }

    /// Orders the commits reachable from `head` the way `git log --date-order` does: newest first
    /// by commit time, but never a parent before all of its children.
    func dateOrder(from head: Int32) -> (rows: [Int32], rowOf: [Int32]) {
        var children = [Int32](repeating: 0, count: count)
        var seen = [Bool](repeating: false, count: count)
        var stack: [Int32] = [head]
        var scratch: [Int32] = []
        var reachable = 0
        seen[Int(head)] = true
        while let commit = stack.popLast() {
            reachable += 1
            scratch.removeAll(keepingCapacity: true)
            parents(of: commit, into: &scratch)
            for parent in scratch {
                children[Int(parent)] += 1
                if !seen[Int(parent)] {
                    seen[Int(parent)] = true
                    stack.append(parent)
                }
            }
        }

        var rows: [Int32] = []
        rows.reserveCapacity(reachable)
        var rowOf = [Int32](repeating: -1, count: count)
        var heap = NewestFirstHeap()
        heap.push(time: commitTime(head), position: head)
        while let commit = heap.pop() {
            rowOf[Int(commit)] = Int32(rows.count)
            rows.append(commit)
            scratch.removeAll(keepingCapacity: true)
            parents(of: commit, into: &scratch)
            for parent in scratch {
                children[Int(parent)] -= 1
                if children[Int(parent)] == 0 { heap.push(time: commitTime(parent), position: parent) }
            }
        }
        return (rows, rowOf)
    }
}

/// A binary max-heap of commits keyed by commit time.
private struct NewestFirstHeap {
    private var items: [(time: Int64, position: Int32)] = []

    mutating func push(time: Int64, position: Int32) {
        items.append((time, position))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            if items[parent].time >= items[child].time { break }
            items.swapAt(parent, child)
            child = parent
        }
    }

    mutating func pop() -> Int32? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var parent = 0
            while true {
                let left = 2 * parent + 1
                let right = left + 1
                var largest = parent
                if left < items.count && items[left].time > items[largest].time { largest = left }
                if right < items.count && items[right].time > items[largest].time { largest = right }
                if largest == parent { break }
                items.swapAt(parent, largest)
                parent = largest
            }
        }
        return top.position
    }
}
