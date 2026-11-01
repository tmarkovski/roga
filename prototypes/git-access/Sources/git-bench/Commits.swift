import Foundation

private let hexValues: [UInt8] = {
    var table = [UInt8](repeating: 0xFF, count: 256)
    for (value, character) in "0123456789abcdef".utf8.enumerated() { table[Int(character)] = UInt8(value) }
    for (value, character) in "ABCDEF".utf8.enumerated() { table[Int(character)] = UInt8(10 + value) }
    return table
}()

private let hexDigits = Array("0123456789abcdef".utf8)

/// A SHA-1 object ID packed into three words so it hashes and compares quickly.
struct OID: Hashable {
    var w0: UInt64
    var w1: UInt64
    var w2: UInt32

    /// Reads 20 raw bytes.
    init(raw p: UnsafeRawPointer) {
        w0 = UInt64(bigEndian: p.loadUnaligned(as: UInt64.self))
        w1 = UInt64(bigEndian: p.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        w2 = UInt32(bigEndian: p.loadUnaligned(fromByteOffset: 16, as: UInt32.self))
    }

    /// Parses the first 40 hex characters of `hex`.
    init?(hex: UnsafeBufferPointer<UInt8>) {
        guard hex.count >= 40 else { return nil }
        var accumulator: UInt64 = 0
        var first: UInt64 = 0
        var second: UInt64 = 0
        var invalid: UInt8 = 0
        for i in 0..<40 {
            let value = hexValues[Int(hex[i])]
            invalid |= value
            accumulator = accumulator << 4 | UInt64(value & 0x0F)
            if i == 15 { first = accumulator; accumulator = 0 }
            if i == 31 { second = accumulator; accumulator = 0 }
        }
        guard invalid & 0xF0 == 0 else { return nil }
        w0 = first
        w1 = second
        w2 = UInt32(accumulator)
    }

    init?(hex: String) {
        var text = hex
        guard let oid = text.withUTF8({ OID(hex: $0) }) else { return nil }
        self = oid
    }

    var hex: String {
        String(unsafeUninitializedCapacity: 40) { buffer in
            func put(_ value: UInt64, nibbles: Int, at offset: Int) {
                for k in 0..<nibbles {
                    buffer[offset + k] = hexDigits[Int((value >> UInt64(4 * (nibbles - 1 - k))) & 0xF)]
                }
            }
            put(w0, nibbles: 16, at: 0)
            put(w1, nibbles: 16, at: 16)
            put(UInt64(w2), nibbles: 8, at: 32)
            return 40
        }
    }

    func hash(into hasher: inout Hasher) { hasher.combine(w0) }
}

struct CommitMeta {
    var author: String
    var email: String
    var time: Int64
    var subject: String
}

/// Commit metadata kept as parallel arrays, roughly the way an app would hold a million commits.
struct CommitTable {
    var oids: [OID] = []
    var parentStart: [Int32] = [0]
    var parents: [OID] = []
    var metas: [CommitMeta] = []

    var count: Int { oids.count }

    mutating func reserve(_ capacity: Int) {
        oids.reserveCapacity(capacity)
        parentStart.reserveCapacity(capacity + 1)
        parents.reserveCapacity(capacity + capacity / 8)
        metas.reserveCapacity(capacity)
    }

    mutating func append(oid: OID, parents commitParents: [OID], meta: CommitMeta) {
        oids.append(oid)
        parents.append(contentsOf: commitParents)
        parentStart.append(Int32(parents.count))
        metas.append(meta)
    }

    /// Parses one record of `git log -z --format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s`.
    mutating func appendLogRecord(_ record: UnsafeBufferPointer<UInt8>) {
        var cursor = FieldCursor(record)
        let hash = cursor.next(0x1F)
        let parentField = cursor.next(0x1F)
        let author = cursor.next(0x1F)
        let email = cursor.next(0x1F)
        let time = cursor.next(0x1F)
        let subject = cursor.rest()
        guard let oid = OID(hex: hash) else { return }

        oids.append(oid)
        var offset = 0
        while offset + 40 <= parentField.count {
            if let parent = OID(hex: UnsafeBufferPointer(rebasing: parentField[offset..<offset + 40])) {
                parents.append(parent)
            }
            offset += 41
        }
        parentStart.append(Int32(parents.count))
        metas.append(CommitMeta(
            author: String(decoding: author, as: UTF8.self),
            email: String(decoding: email, as: UTF8.self),
            time: parseInt(time),
            subject: String(decoding: subject, as: UTF8.self)
        ))
    }

    /// Maps each commit to its row and lays out the graph, as an app must after loading.
    func layout() -> GraphLayout {
        var rowOf = [OID: Int32](minimumCapacity: count)
        for (row, oid) in oids.enumerated() { rowOf[oid] = Int32(row) }
        return layoutGraph(rowCount: count) { row, out in
            for k in Int(parentStart[row])..<Int(parentStart[row + 1]) {
                if let parentRow = rowOf[parents[k]] { out.append(parentRow) }
            }
        }
    }
}

struct GraphLayout {
    var columns: [Int32]
    var maxWidth: Int
    /// How many lanes are open at each row, when requested.
    var widths: [UInt16] = []
}

/// Assigns each row a column in the commit graph. `parentRows` appends the rows of a row's parents.
func layoutGraph(rowCount: Int, recordWidths: Bool = false,
                 parentRows: (Int, inout [Int32]) -> Void) -> GraphLayout {
    var columns = [Int32](repeating: 0, count: rowCount)
    var widths = [UInt16](repeating: 0, count: recordWidths ? rowCount : 0)
    var lanes: [Int32] = []
    var parents: [Int32] = []
    var maxWidth = 0
    for row in 0..<rowCount {
        let current = Int32(row)
        var column = -1
        for i in lanes.indices where lanes[i] == current {
            if column < 0 { column = i } else { lanes[i] = -1 }
        }
        if column < 0 {
            if let free = lanes.firstIndex(of: -1) {
                column = free
            } else {
                column = lanes.count
                lanes.append(-1)
            }
        }
        parents.removeAll(keepingCapacity: true)
        parentRows(row, &parents)
        if let first = parents.first {
            lanes[column] = first
            for parent in parents.dropFirst() where !lanes.contains(parent) {
                if let free = lanes.firstIndex(of: -1) { lanes[free] = parent } else { lanes.append(parent) }
            }
        } else {
            lanes[column] = -1
        }
        while lanes.last == -1 { lanes.removeLast() }
        columns[row] = Int32(column)
        maxWidth = max(maxWidth, lanes.count)
        if recordWidths { widths[row] = UInt16(clamping: max(lanes.count, column + 1)) }
    }
    return GraphLayout(columns: columns, maxWidth: maxWidth, widths: widths)
}
