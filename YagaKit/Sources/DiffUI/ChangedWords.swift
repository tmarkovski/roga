import Foundation
import GitCore

/// Finds the parts of a patch's changed lines that differ from the other side,
/// which is how someone sees what changed within a line.
///
/// Each run of removed and added lines is compared as a whole rather than line
/// by line, so nothing has to guess which added line came from which removed
/// one, and a word that moves to the next line, as in a reflowed comment, doesn't
/// count as changed. Spaces aren't compared this way, because they would match
/// as readily as the words do. They differ only where the words around them
/// are the same, as when a line is indented further.
nonisolated enum ChangedWords {
    /// The most differences to look for in a run. Looking takes time and memory
    /// with the square of this, and a run that differs this much is a rewrite,
    /// so it shows no marks.
    static let differenceLimit = 1_000

    /// How much of a line has to stay the same for it to show marks, not
    /// counting spaces. With less than this it was replaced, which its
    /// background says already, and a mark on all of it would only be louder.
    static let leastShareInCommon = 0.3

    /// The parts that differ, in order, in UTF-16 code units of the patch's text.
    static func ranges(in text: [UInt16], lines: [FilePatch.Line], lineStarts: [Int]) -> [NSRange] {
        var ranges: [NSRange] = []
        var index = 0
        while index < lines.count, !Task.isCancelled {
            guard lines[index].kind == .removed || lines[index].kind == .added else {
                index += 1
                continue
            }
            var end = index + 1
            // git's remark that a line has no newline can come between them.
            while end < lines.count, lines[end].kind == .removed || lines[end].kind == .added || lines[end].kind == .noNewline { end += 1 }
            Run(text: text, lines: lines, lineStarts: lineStarts, range: index..<end).appendRanges(to: &ranges)
            index = end
        }
        return ranges
    }

    private enum CharacterKind {
        case word, space, punctuation

        init(_ unit: UInt16) {
            switch unit {
            case 0x20, 0x09: self = .space
            // Anything outside ASCII counts as a word, which keeps the two
            // halves of a character together.
            case 0x30...0x39, 0x41...0x5A, 0x5F, 0x61...0x7A, 0x80...: self = .word
            default: self = .punctuation
            }
        }
    }

    /// The words of one side of a run.
    private struct Side {
        /// Its runs of letters and digits, and its single punctuation marks.
        var words: [Range<Int>] = []
        /// A hash of each word. Comparing these is most of the time a long run
        /// takes, and if two words ever had the same hash, one would go unmarked.
        var hashes: [UInt64] = []
        /// The word on the other side that each is paired with, or -1.
        var partners: [Int32] = []
        /// The first word that isn't in a line gone through yet.
        var next = 0
    }

    /// Lines next to each other that were removed or added.
    private struct Run {
        let text: [UInt16]
        let lines: [FilePatch.Line]
        let lineStarts: [Int]
        let range: Range<Int>

        func appendRanges(to ranges: inout [NSRange]) {
            var removed = Side()
            var added = Side()
            for line in range {
                switch lines[line].kind {
                case .removed: appendWords(ofLine: line, to: &removed)
                case .added: appendWords(ofLine: line, to: &added)
                default: break
                }
            }
            // Lines with nothing to compare with are all new, or all gone.
            guard !removed.words.isEmpty, !added.words.isEmpty, pairWords(&removed, &added) else { return }

            for line in range {
                switch lines[line].kind {
                case .removed: appendRanges(ofLine: line, &removed, other: added, to: &ranges)
                case .added: appendRanges(ofLine: line, &added, other: removed, to: &ranges)
                default: break
                }
            }
        }

        private func characters(ofLine line: Int) -> Range<Int> {
            var end = (line + 1 < lineStarts.count ? lineStarts[line + 1] : text.count) - 1
            // A carriage return at the end of a line can't be seen.
            if end > lineStarts[line], text[end - 1] == 0x0D { end -= 1 }
            return lineStarts[line]..<end
        }

        private func appendWords(ofLine line: Int, to side: inout Side) {
            let characters = characters(ofLine: line)
            var start = characters.lowerBound
            while start < characters.upperBound {
                let kind = CharacterKind(text[start])
                var end = start + 1
                if kind != .punctuation {
                    while end < characters.upperBound, CharacterKind(text[end]) == kind { end += 1 }
                }
                if kind != .space {
                    side.words.append(start..<end)
                    // FNV-1a.
                    side.hashes.append(text[start..<end].reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 })
                }
                start = end
            }
        }

        /// Adds what differs in a line, as one range for words with only spaces
        /// between them, and goes past the line's words.
        private func appendRanges(ofLine line: Int, _ side: inout Side, other: Side, to ranges: inout [NSRange]) {
            let characters = characters(ofLine: line)
            let first = ranges.count
            var inCommon = 0
            var different = 0

            func mark(_ range: Range<Int>) {
                guard !range.isEmpty else { return }
                if ranges.count > first, text[ranges[ranges.count - 1].upperBound..<range.lowerBound].allSatisfy({ CharacterKind($0) == .space }) {
                    ranges[ranges.count - 1].length = range.upperBound - ranges[ranges.count - 1].location
                } else {
                    ranges.append(NSRange(location: range.lowerBound, length: range.count))
                }
            }

            var lastPartner: Range<Int>?
            var lastWord: Range<Int>?
            while side.next < side.words.count, side.words[side.next].lowerBound < characters.upperBound {
                let index = side.next
                side.next += 1
                let word = side.words[index]
                lastWord = word
                let partner = Int(side.partners[index])
                guard partner >= 0 else {
                    different += word.count
                    lastPartner = nil
                    mark(word)
                    continue
                }
                inCommon += word.count
                lastPartner = other.words[partner]
                let gap = spaces(before: word)
                let otherGap = spaces(before: other.words[partner])
                let isSameGap = isLineStart(gap.lowerBound)
                    ? isLineStart(otherGap.lowerBound)
                    : !isLineStart(otherGap.lowerBound) && index > 0 && partner > 0 && Int(side.partners[index - 1]) == partner - 1
                if isSameGap { mark(partOfSpaces(gap, thatDifferFrom: otherGap)) }
            }
            if let lastWord, let lastPartner {
                let gap = spaces(after: lastWord)
                let otherGap = spaces(after: lastPartner)
                if isLineEnd(otherGap.upperBound) { mark(partOfSpaces(gap, thatDifferFrom: otherGap)) }
            }

            if Double(inCommon) < leastShareInCommon * Double(inCommon + different) {
                ranges.removeSubrange(first...)
            }
        }

        private func spaces(before word: Range<Int>) -> Range<Int> {
            var start = word.lowerBound
            while start > 0, CharacterKind(text[start - 1]) == .space { start -= 1 }
            return start..<word.lowerBound
        }

        private func spaces(after word: Range<Int>) -> Range<Int> {
            var end = word.upperBound
            while end < text.count, CharacterKind(text[end]) == .space { end += 1 }
            return word.upperBound..<end
        }

        /// Leaves out what the start and the end of some spaces have in common
        /// with others, so that a line indented further marks only the extra.
        private func partOfSpaces(_ spaces: Range<Int>, thatDifferFrom other: Range<Int>) -> Range<Int> {
            var start = spaces.lowerBound
            var otherStart = other.lowerBound
            while start < spaces.upperBound, otherStart < other.upperBound, text[start] == text[otherStart] {
                start += 1
                otherStart += 1
            }
            var end = spaces.upperBound
            var otherEnd = other.upperBound
            while end > start, otherEnd > otherStart, text[end - 1] == text[otherEnd - 1] {
                end -= 1
                otherEnd -= 1
            }
            return start..<end
        }

        private func isLineStart(_ position: Int) -> Bool {
            position == 0 || text[position - 1] == 0x0A
        }

        private func isLineEnd(_ position: Int) -> Bool {
            position == text.count || text[position] == 0x0A || text[position] == 0x0D
        }

        /// Pairs the words that the two sides have in common, with Myers' greedy
        /// algorithm for the shortest edit, or returns false if the sides have
        /// more than `differenceLimit` differences.
        private func pairWords(_ old: inout Side, _ new: inout Side) -> Bool {
            let oldHashes = old.hashes
            let newHashes = new.hashes
            let limit = min(oldHashes.count + newHashes.count, differenceLimit)
            let middle = limit + 1
            // How far along the old side each diagonal has got, where a diagonal
            // is how far the old side is ahead of the new side.
            var furthest = [Int32](repeating: 0, count: middle * 2 + 1)
            // All of those for each number of differences, to find the way back.
            var trace: [Int32] = []

            for differences in 0...limit {
                for diagonal in stride(from: -differences, through: differences, by: 2) {
                    let below = Int(furthest[middle + diagonal - 1])
                    let above = Int(furthest[middle + diagonal + 1])
                    var x = diagonal == -differences || (diagonal != differences && below < above) ? above : below + 1
                    var y = x - diagonal
                    while x < oldHashes.count, y < newHashes.count, oldHashes[x] == newHashes[y] {
                        x += 1
                        y += 1
                    }
                    furthest[middle + diagonal] = Int32(x)
                    trace.append(Int32(x))
                    if x >= oldHashes.count, y >= newHashes.count {
                        pairWords(&old, &new, differences: differences, trace: trace)
                        return true
                    }
                }
            }
            return false
        }

        /// Goes back along the way the search came, pairing the words it passed
        /// without a difference.
        private func pairWords(_ old: inout Side, _ new: inout Side, differences: Int, trace: [Int32]) {
            // Each number of differences has one more diagonal than the one before.
            func reached(_ differences: Int, _ diagonal: Int) -> Int {
                Int(trace[differences * (differences + 1) / 2 + (diagonal + differences) / 2])
            }
            old.partners = Array(repeating: -1, count: old.words.count)
            new.partners = Array(repeating: -1, count: new.words.count)
            var x = old.words.count
            var y = new.words.count
            func pairBack(to start: Int) {
                while x > start {
                    x -= 1
                    y -= 1
                    old.partners[x] = Int32(y)
                    new.partners[y] = Int32(x)
                }
            }
            for step in stride(from: differences, to: 0, by: -1) {
                let diagonal = x - y
                let isFromAbove = diagonal == -step || (diagonal != step && reached(step - 1, diagonal - 1) < reached(step - 1, diagonal + 1))
                let previousDiagonal = isFromAbove ? diagonal + 1 : diagonal - 1
                let previousX = reached(step - 1, previousDiagonal)
                pairBack(to: isFromAbove ? previousX : previousX + 1)
                x = previousX
                y = previousX - previousDiagonal
            }
            pairBack(to: 0)
        }
    }
}
