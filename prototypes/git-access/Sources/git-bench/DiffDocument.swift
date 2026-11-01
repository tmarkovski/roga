import Foundation

/// A unified diff split into lines. The text stays in one byte buffer with offsets, so a million
/// lines cost a few arrays rather than a million strings.
final class DiffDocument {
    enum Kind: UInt8 {
        case fileHeader, hunkHeader, context, added, removed
    }

    let bytes: [UInt8]
    private(set) var lineStarts: [Int32] = []
    private(set) var lineEnds: [Int32] = []
    private(set) var kinds: [Kind] = []
    private(set) var oldNumbers: [Int32] = []
    private(set) var newNumbers: [Int32] = []
    /// For a removed or added line, the line it replaces or is replaced by, or -1.
    private(set) var pairs: [Int32] = []
    private(set) var fileCount = 0

    var count: Int { kinds.count }

    init(bytes: [UInt8]) {
        self.bytes = bytes
        parse()
    }

    private func parse() {
        var oldLine: Int32 = 0
        var newLine: Int32 = 0
        var oldLeft = 0
        var newLeft = 0
        var runStart = 0
        var runRemoved = 0
        var runAdded = 0
        var previous = Kind.fileHeader

        bytes.withUnsafeBufferPointer { all in
            guard let base = all.baseAddress else { return }
            var start = 0
            while start < all.count {
                let end = memchr(base + start, 0x0A, all.count - start)
                    .map { UnsafeRawPointer($0) - UnsafeRawPointer(base) } ?? all.count
                let line = UnsafeBufferPointer(rebasing: all[start..<end])
                let first = line.first ?? 0
                var kind: Kind
                var old: Int32 = 0
                var new: Int32 = 0

                if oldLeft > 0 || newLeft > 0 {
                    switch first {
                    case UInt8(ascii: "+"):
                        kind = .added
                        new = newLine
                        newLine += 1
                        newLeft -= 1
                    case UInt8(ascii: "-"):
                        kind = .removed
                        old = oldLine
                        oldLine += 1
                        oldLeft -= 1
                    case UInt8(ascii: "\\"):
                        kind = .context // "\ No newline at end of file"
                    default:
                        kind = .context
                        old = oldLine
                        new = newLine
                        oldLine += 1
                        newLine += 1
                        oldLeft -= 1
                        newLeft -= 1
                    }
                } else if line.starts(with: "@@ ".utf8) {
                    kind = .hunkHeader
                    let header = String(decoding: line, as: UTF8.self).split(separator: " ")
                    if header.count >= 3 {
                        (oldLine, oldLeft) = Self.parseRange(header[1])
                        (newLine, newLeft) = Self.parseRange(header[2])
                    }
                } else {
                    kind = .fileHeader
                    if line.starts(with: "diff --git ".utf8) { fileCount += 1 }
                }

                // Pair each removed line with the added line in the same position of the run
                // that follows it, so the changed words between them can be highlighted.
                let index = kinds.count
                var partner: Int32 = -1
                switch kind {
                case .removed:
                    if previous != .removed {
                        runStart = index
                        runRemoved = 0
                        runAdded = 0
                    }
                    runRemoved += 1
                case .added:
                    if (previous == .removed || previous == .added) && runAdded < runRemoved {
                        partner = Int32(runStart + runAdded)
                        pairs[runStart + runAdded] = Int32(index)
                        runAdded += 1
                    }
                default:
                    runRemoved = 0
                }

                lineStarts.append(Int32(start))
                lineEnds.append(Int32(end))
                kinds.append(kind)
                oldNumbers.append(old)
                newNumbers.append(new)
                pairs.append(partner)
                previous = kind
                start = end + 1
            }
        }
    }

    /// Parses `-12,5` or `+12` from a hunk header into a starting line and a line count.
    private static func parseRange(_ text: Substring) -> (Int32, Int) {
        let parts = text.dropFirst().split(separator: ",")
        let start = Int32(parts.first ?? "") ?? 0
        let count = parts.count > 1 ? Int(parts[1]) ?? 0 : 1
        return (start, count)
    }

    func withLine<T>(_ line: Int, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        bytes.withUnsafeBufferPointer { all in
            body(UnsafeBufferPointer(rebasing: all[Int(lineStarts[line])..<Int(lineEnds[line])]))
        }
    }

    /// The line's text with tabs expanded to every eighth column, counting from after the
    /// leading `+`, `-` or space.
    func displayText(_ line: Int) -> String {
        withLine(line) { bytes in
            guard bytes.contains(0x09) else { return String(decoding: bytes, as: UTF8.self) }
            var expanded: [UInt8] = []
            expanded.reserveCapacity(bytes.count + 16)
            for byte in bytes {
                if byte == 0x09 {
                    repeat { expanded.append(0x20) } while (expanded.count - 1) % 8 != 0
                } else {
                    expanded.append(byte)
                }
            }
            return String(decoding: expanded, as: UTF8.self)
        }
    }

    /// The changed middle of a line compared with its partner, as byte offsets within the line.
    func changedRange(_ line: Int) -> Range<Int>? {
        let partner = Int(pairs[line])
        guard partner >= 0 else { return nil }
        return withLine(line) { mine in
            withLine(partner) { theirs in
                let a = mine.dropFirst()
                let b = theirs.dropFirst()
                let limit = min(a.count, b.count)
                var prefix = 0
                while prefix < limit && a[a.startIndex + prefix] == b[b.startIndex + prefix] { prefix += 1 }
                var suffix = 0
                while suffix < limit - prefix && a[a.endIndex - 1 - suffix] == b[b.endIndex - 1 - suffix] { suffix += 1 }
                let range = (1 + prefix)..<(1 + a.count - suffix)
                return range.isEmpty ? nil : range
            }
        }
    }

    /// Converts a byte offset within a line to a display column, expanding tabs.
    func column(_ line: Int, byteOffset: Int) -> Int {
        withLine(line) { bytes in
            var column = 0
            for byte in bytes.prefix(byteOffset) {
                if byte == 0x09 {
                    repeat { column += 1 } while (column - 1) % 8 != 0
                } else if byte & 0xC0 != 0x80 {
                    column += 1
                }
            }
            return column
        }
    }

    /// The number of UTF-16 code units in part of a line, which is how `NSString` measures text.
    func utf16Length(_ line: Int, bytes range: Range<Int>? = nil) -> Int {
        withLine(line) { bytes in
            var count = 0
            for byte in bytes[(range ?? 0..<bytes.count)] where byte & 0xC0 != 0x80 {
                count += byte >= 0xF0 ? 2 : 1
            }
            return count
        }
    }
}
