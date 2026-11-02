import Darwin
import GitCore

/// One commit-graph file mapped into memory: either a repository's single
/// file, `objects/info/commit-graph`, or one layer of a split chain.
///
/// Opening a file checks its structure, so that reading any of its commits
/// stays inside the file. The values a commit points to, such as its parents,
/// are checked when they're read. git's `gitformat-commit-graph`
/// documentation describes the format.
final class CommitGraphFile: Sendable {
    let path: String
    let format: ObjectFormat
    /// The number of commits in this file.
    let count: Int
    /// The number of layers below this one in its chain, from the header.
    let baseLayerCount: Int
    /// The hash at the end of the file. A chain names its layers by it.
    let checksum: ObjectID
    /// Whether the file stores corrected commit dates, which git calls
    /// generation numbers v2. Files without them have only topological levels.
    var hasCorrectedCommitDates: Bool { generationData != nil }

    // The mapping is read-only and lives as long as the file, so reading it
    // from any thread is safe.
    private nonisolated(unsafe) let base: UnsafeRawPointer
    private let size: Int
    private let fanout: Int
    private let lookup: Int
    private let data: Int
    private let entrySize: Int
    private let edges: Int
    private let edgeCount: Int
    private let generationData: Int?
    private let generationOverflow: Int
    private let overflowCount: Int
    private let baseGraphs: Int?

    /// The value of a parent field when there's no parent.
    static let noParent: UInt32 = 0x7000_0000

    private enum Chunk {
        static let fanout: UInt32 = 0x4F49_4446             // OIDF
        static let lookup: UInt32 = 0x4F49_444C             // OIDL
        static let data: UInt32 = 0x4344_4154               // CDAT
        static let generationData: UInt32 = 0x4744_4132     // GDA2
        static let generationOverflow: UInt32 = 0x4744_4F32 // GDO2
        static let edges: UInt32 = 0x4544_4745              // EDGE
        static let baseGraphs: UInt32 = 0x4241_5345         // BASE
    }

    init(path: String, format: ObjectFormat) throws(CommitGraphError) {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw .cannotRead(path: path, errorNumber: errno) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .cannotRead(path: path, errorNumber: errno) }
        let size = Int(info.st_size)
        // The header, the end of the chunk table, and the checksum.
        guard size >= 8 + 12 + format.byteCount else {
            throw .invalid(path: path, reason: "The file is too short.")
        }
        let mapping = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0)
        guard let mapping, mapping != UnsafeMutableRawPointer(bitPattern: -1) else {
            throw .cannotRead(path: path, errorNumber: errno)
        }
        let base = UnsafeRawPointer(mapping)
        // Commits are sorted by ID, so walking even a little history reads
        // pages from all over the file. From a cold disk cache, waiting for
        // each page as the walk reaches it took 0.4 seconds for Linux's first
        // screen, so ask for the whole file now, in the background.
        var readAhead = radvisory(ra_offset: 0, ra_count: Int32(clamping: size))
        _ = fcntl(descriptor, F_RDADVISE, &readAhead)

        func fail(_ reason: String) -> CommitGraphError {
            munmap(mapping, size)
            return .invalid(path: path, reason: reason)
        }
        func uint32(_ offset: Int) -> UInt32 {
            UInt32(bigEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
        func uint64(_ offset: Int) -> UInt64 {
            UInt64(bigEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }

        guard uint32(0) == 0x4347_5048 else { throw fail("The file doesn't start with CGPH.") }
        let version = base.load(fromByteOffset: 4, as: UInt8.self)
        guard version == 1 else { throw fail("The file has version \(version), and only version 1 is known.") }
        let hashVersion = base.load(fromByteOffset: 5, as: UInt8.self)
        guard hashVersion == (format == .sha1 ? 1 : 2) else {
            throw fail("The file uses hash version \(hashVersion), which doesn't match the repository's \(format).")
        }
        let chunkCount = Int(base.load(fromByteOffset: 6, as: UInt8.self))
        let trailer = size - format.byteCount

        // The chunk table has an entry for each chunk and one that marks the
        // end of the last chunk. Each chunk ends where the next one starts.
        guard 8 + (chunkCount + 1) * 12 <= trailer else { throw fail("The chunk table runs past the end of the file.") }
        var chunks: [UInt32: Range<Int>] = [:]
        for index in 0..<chunkCount {
            let entry = 8 + index * 12
            let id = uint32(entry)
            let start = uint64(entry + 4)
            let end = uint64(entry + 16)
            guard id != 0 else { throw fail("The chunk table ends early.") }
            guard start <= end, end <= UInt64(trailer) else { throw fail("A chunk lies outside the file.") }
            guard chunks.updateValue(Int(start)..<Int(end), forKey: id) == nil else {
                throw fail("The file has two chunks with the same ID.")
            }
        }
        guard uint32(8 + chunkCount * 12) == 0 else { throw fail("The chunk table doesn't end where the header says.") }

        guard let fanout = chunks[Chunk.fanout], fanout.count == 256 * 4 else {
            throw fail("The fanout chunk is missing or the wrong size.")
        }
        for index in 0..<255 where uint32(fanout.lowerBound + index * 4) > uint32(fanout.lowerBound + (index + 1) * 4) {
            throw fail("The fanout table isn't in order.")
        }
        let count = Int(uint32(fanout.lowerBound + 255 * 4))
        let entrySize = format.byteCount + 16
        guard let lookup = chunks[Chunk.lookup], lookup.count == count * format.byteCount else {
            throw fail("The ID lookup chunk is missing or the wrong size.")
        }
        guard let data = chunks[Chunk.data], data.count == count * entrySize else {
            throw fail("The commit data chunk is missing or the wrong size.")
        }
        let edges = chunks[Chunk.edges]
        guard (edges?.count ?? 0) % 4 == 0 else { throw fail("The extra edges chunk is the wrong size.") }
        let generationData = chunks[Chunk.generationData]
        guard generationData == nil || generationData?.count == count * 4 else {
            throw fail("The generation data chunk is the wrong size.")
        }
        let generationOverflow = chunks[Chunk.generationOverflow]
        guard (generationOverflow?.count ?? 0) % 8 == 0 else {
            throw fail("The generation overflow chunk is the wrong size.")
        }
        let baseLayerCount = Int(base.load(fromByteOffset: 7, as: UInt8.self))
        let baseGraphs = chunks[Chunk.baseGraphs]
        guard baseLayerCount == 0 || (baseGraphs?.count ?? 0) >= baseLayerCount * format.byteCount else {
            throw fail("The base graphs chunk is missing or too small.")
        }

        self.path = path
        self.format = format
        self.count = count
        self.baseLayerCount = baseLayerCount
        self.checksum = ObjectID(loading: base + trailer, format: format)
        self.base = base
        self.size = size
        self.fanout = fanout.lowerBound
        self.lookup = lookup.lowerBound
        self.data = data.lowerBound
        self.entrySize = entrySize
        self.edges = edges?.lowerBound ?? 0
        self.edgeCount = (edges?.count ?? 0) / 4
        self.generationData = generationData?.lowerBound
        self.generationOverflow = generationOverflow?.lowerBound ?? 0
        self.overflowCount = (generationOverflow?.count ?? 0) / 8
        self.baseGraphs = baseGraphs?.lowerBound
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: base), size)
    }

    /// The checksums of the layers below this one, from the base graphs chunk,
    /// lowest first.
    var baseChecksums: [ObjectID] {
        guard let baseGraphs else { return [] }
        return (0..<baseLayerCount).map { ObjectID(loading: base + baseGraphs + $0 * format.byteCount, format: format) }
    }

    /// Finds a commit by binary search, narrowed by the fanout table, and
    /// returns its index in this file.
    func index(of id: ObjectID) -> Int? {
        guard id.format == format else { return nil }
        let firstByte = Int(id.byte(at: 0))
        var low = firstByte == 0 ? 0 : Int(uint32(fanout + (firstByte - 1) * 4))
        var high = Int(uint32(fanout + firstByte * 4))
        while low < high {
            let middle = (low + high) / 2
            let candidate = self.id(at: middle)
            if candidate == id { return middle }
            if candidate < id { low = middle + 1 } else { high = middle }
        }
        return nil
    }

    func id(at index: Int) -> ObjectID {
        ObjectID(loading: base + lookup + index * format.byteCount, format: format)
    }

    /// The committer date, in seconds since 1970. The file stores 34 bits.
    func commitTime(at index: Int) -> Int64 {
        let entry = data + index * entrySize + format.byteCount
        return Int64(uint32(entry + 8) & 0x3) << 32 | Int64(uint32(entry + 12))
    }

    /// The commit's topological level, which git calls generation number v1:
    /// 1 for a commit without parents, and otherwise one more than its
    /// highest parent. It's 0 in files written before git stored levels.
    func topologicalLevel(at index: Int) -> UInt32 {
        uint32(data + index * entrySize + format.byteCount + 8) >> 2
    }

    /// The commit's corrected commit date, which git calls generation number
    /// v2: its commit time, raised where needed to be later than all of its
    /// parents'. Only call this when the file has corrected commit dates.
    func correctedCommitDate(at index: Int) throws(CommitGraphError) -> UInt64 {
        guard let generationData else { preconditionFailure("\(path) has no corrected commit dates") }
        let time = UInt64(commitTime(at: index))
        let offset = uint32(generationData + index * 4)
        guard offset & 0x8000_0000 != 0 else { return time &+ UInt64(offset) }
        // Offsets that don't fit in 31 bits are in the overflow chunk.
        let overflow = Int(offset & 0x7FFF_FFFF)
        guard overflow < overflowCount else {
            throw .invalid(path: path, reason: "Commit \(id(at: index)) has a generation number outside the file.")
        }
        return time &+ uint64(generationOverflow + overflow * 8)
    }

    /// The position of the commit's parent at `parentIndex`, or nil when it
    /// has fewer parents. `limit` is the number of commits in this layer and
    /// the layers below it, and every parent's position has to be lower.
    func parent(at index: Int, _ parentIndex: Int, limit: Int) throws(CommitGraphError) -> UInt32? {
        let entry = data + index * entrySize + format.byteCount
        let parent: UInt32
        if parentIndex == 0 {
            parent = uint32(entry)
            // A commit without a first parent has no parents at all.
            guard parent != Self.noParent else { return nil }
        } else {
            let second = uint32(entry + 4)
            guard second != Self.noParent else { return nil }
            if second & 0x8000_0000 == 0 {
                guard parentIndex == 1 else { return nil }
                parent = second
            } else {
                // A commit with more than two parents lists the second and
                // later ones in the extra edges chunk. The last one has its
                // top bit set.
                let edge = Int(second & 0x7FFF_FFFF) + parentIndex - 1
                if parentIndex > 1 {
                    guard edge - 1 < edgeCount else { throw badParent(at: index) }
                    guard uint32(edges + (edge - 1) * 4) & 0x8000_0000 == 0 else { return nil }
                }
                guard edge < edgeCount else { throw badParent(at: index) }
                parent = uint32(edges + edge * 4) & 0x7FFF_FFFF
            }
        }
        guard Int(parent) < limit else { throw badParent(at: index) }
        return parent
    }

    private func badParent(at index: Int) -> CommitGraphError {
        .invalid(path: path, reason: "Commit \(id(at: index)) has a parent outside the commit-graph.")
    }

    private func uint32(_ offset: Int) -> UInt32 {
        UInt32(bigEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    private func uint64(_ offset: Int) -> UInt64 {
        UInt64(bigEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
}
