/// Decides which tier each label of a replay sits on over time, above or below
/// the main line (decision 62).
///
/// A label lands on the lowest tier it can and pushes up whatever it overlaps.
/// Once no new label can reach it, it falls as soon as there's room below it,
/// and from then on it stays where it fell. How tall a stack gets comes only
/// from how much its labels overlap.
///
/// All of a replay's moves are worked out in one go, in the order the labels
/// land, so that a frame can look up where a label is at any moment, however
/// the replay got there.
enum LabelStacks {
    struct Item: Equatable {
        /// Where the label starts, and how wide it is, in points.
        var start: Double
        var width: Double
        var isAbove: Bool
        /// The tier nearest the main line that's allowed. A branch's label
        /// starts past its own lane.
        var lowestTier = 0
        /// When it lands.
        var time: Double

        var end: Double { start + width }
    }

    /// A label arriving on a tier.
    struct Move: Equatable {
        var time: Double
        var tier: Int
    }

    /// How far apart two labels on a tier have to be.
    static let slack = 10.0
    /// How long a label takes to move away from the main line, and to fall
    /// back toward it. A fall is usually across several tiers, so taking
    /// longer keeps it about as fast as a rise of one.
    static let riseTime = 0.25
    static let fallTime = riseTime * 3

    /// Returns each label's moves, starting with where it lands. `items` goes
    /// from oldest to newest.
    static func moves(of items: [Item]) -> [[Move]] {
        var moves = [[Move]](repeating: [], count: items.count)
        for isAbove in [true, false] {
            var side = Side(items: items)
            for index in items.indices where items[index].isAbove == isAbove {
                side.land(index, recordingIn: &moves)
            }
        }
        return moves
    }

    /// How much of a move a label hasn't made yet, `age` seconds after it
    /// began. `distance` is positive away from the main line. A rise starts
    /// at once and settles, and a fall eases in as well, so that it doesn't
    /// drop.
    static func remaining(of distance: Double, age: Double) -> Double {
        if distance > 0 {
            let left = 1 - min(1, max(0, age / riseTime))
            return distance * left * left * left
        }
        let done = min(1, max(0, age / fallTime))
        return distance * (1 - done * done * (3 - 2 * done))
    }

    /// One side of the main line, as labels land on it.
    private struct Side {
        let items: [Item]
        /// Who's on each tier.
        var tiers: [[Int]] = []
        var tierOf: [Int]
        var hasSettled: [Bool]
        /// The labels that have landed and could still move.
        var loose: [Int] = []

        init(items: [Item]) {
            self.items = items
            tierOf = [Int](repeating: 0, count: items.count)
            hasSettled = [Bool](repeating: false, count: items.count)
        }

        func overlap(_ first: Int, _ second: Int) -> Bool {
            items[first].start <= items[second].end + slack && items[second].start <= items[first].end + slack
        }

        mutating func land(_ landing: Int, recordingIn moves: inout [[Move]]) {
            let item = items[landing]
            // No later label can reach these, so they only wait for room.
            // Taking them off first means they don't get pushed up on their
            // way down.
            let cleared = loose.filter { items[$0].end + slack < item.start }.sorted()
            for label in cleared { tiers[tierOf[label]].removeAll { $0 == label } }
            loose = loose.filter { items[$0].end + slack >= item.start }

            insert(landing, at: item.lowestTier)
            loose.append(landing)

            for label in cleared {
                let old = tierOf[label]
                let new = lowestFreeTier(for: label)
                put(label, on: new)
                if new < old || !canStillFall(label) {
                    hasSettled[label] = true
                } else {
                    loose.append(label)
                }
            }

            for label in loose + cleared where moves[label].last?.tier != tierOf[label] {
                moves[label].append(Move(time: item.time, tier: tierOf[label]))
            }
            forgetWhatNothingCanTouch(before: loose.map { items[$0].start }.min() ?? item.start)
        }

        /// Puts a label on a tier and pushes up anything loose that it
        /// overlaps there. A label that has settled stays put, so one being
        /// pushed goes over it instead.
        mutating func insert(_ label: Int, at wanted: Int) {
            var tier = wanted
            while tier < tiers.count, tiers[tier].contains(where: { hasSettled[$0] && overlap($0, label) }) {
                tier += 1
            }
            var pushed: [Int] = []
            if tier < tiers.count {
                pushed = tiers[tier].filter { overlap($0, label) }
                tiers[tier] = tiers[tier].filter { !overlap($0, label) }
            }
            put(label, on: tier)
            for other in pushed { insert(other, at: tier + 1) }
        }

        func lowestFreeTier(for label: Int) -> Int {
            var tier = items[label].lowestTier
            while tier < tiers.count, tiers[tier].contains(where: { overlap($0, label) }) {
                tier += 1
            }
            return tier
        }

        /// Whether a tier below this label could still come free for it. One
        /// held up by a label that has settled there never will.
        func canStillFall(_ label: Int) -> Bool {
            (items[label].lowestTier ..< max(items[label].lowestTier, tierOf[label])).contains { tier in
                !tiers[tier].contains { hasSettled[$0] && overlap($0, label) }
            }
        }

        mutating func put(_ label: Int, on tier: Int) {
            while tiers.count <= tier { tiers.append([]) }
            tiers[tier].append(label)
            tierOf[label] = tier
        }

        mutating func forgetWhatNothingCanTouch(before start: Double) {
            for tier in tiers.indices {
                tiers[tier] = tiers[tier].filter { !hasSettled[$0] || items[$0].end + slack >= start }
            }
        }
    }
}
