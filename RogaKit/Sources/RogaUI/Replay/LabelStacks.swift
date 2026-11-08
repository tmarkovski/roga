/// Decides which tier each label of a replay sits on, above or below the main
/// line (decision 62).
///
/// The newest label takes the lowest tier it can, and each older one takes the
/// lowest tier still free, so a label that a newer one overlaps ends up above
/// it, and a label on top comes back down as soon as the newest ones clear it.
/// How tall a stack gets comes from how much its labels overlap. The only limit
/// is the room in the picture.
///
/// Going by nothing but the labels that have landed makes a stack the same at
/// every moment, however the replay got there.
enum LabelStacks {
    struct Item: Equatable {
        /// Where the label starts, and how wide it is, in points.
        var start: Double
        var width: Double
        var isAbove: Bool
        /// The tier nearest the main line that's allowed. A branch's label
        /// starts past its own lane.
        var lowestTier = 0
    }

    /// How far apart two labels on a tier have to be.
    static let slack = 10.0

    /// Returns each label's tier, or nil when there's no room for it.
    /// `items` goes from oldest to newest.
    static func tiers(of items: [Item], tiersAbove: Int, tiersBelow: Int) -> [Int?] {
        // Newest first, so each tier only has to remember its leftmost label.
        var above = [Double](repeating: .infinity, count: max(tiersAbove, 0))
        var below = [Double](repeating: .infinity, count: max(tiersBelow, 0))
        var tiers = [Int?](repeating: nil, count: items.count)
        for index in items.indices.reversed() {
            tiers[index] = items[index].isAbove ? place(items[index], in: &above) : place(items[index], in: &below)
        }
        return tiers
    }

    private static func place(_ item: Item, in leftEdges: inout [Double]) -> Int? {
        let end = item.start + item.width + slack
        var tier = item.lowestTier
        while tier < leftEdges.count {
            if end < leftEdges[tier] {
                leftEdges[tier] = item.start
                return tier
            }
            tier += 1
        }
        return nil
    }
}
