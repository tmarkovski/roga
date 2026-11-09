import Foundation
import GitCore

extension HistoryReplay {
    /// What stands out in a replay, which the picture points out as it plays
    /// and sums up at the end (decision 64). Anything that doesn't stand out,
    /// such as the busiest day of a replay that covers only one, is nil.
    public struct Highlights: Sendable, Equatable {
        /// A run of commits in a row that were made on the same calendar day.
        public struct Day: Sendable, Equatable {
            /// The day's first commit, as an index into `commits`.
            public var first: Int
            public var commits: Int
            /// Midnight at the start of the day.
            public var start: Date
            /// Which day of the replay it is, from 1. Days without a commit
            /// count too.
            public var number: Int

            /// The day's last commit, as an index into `commits`.
            public var last: Int { first + commits - 1 }
        }

        public var days: [Day] = []
        /// How many calendar days the replay covers, from its first commit's
        /// to its last's, including any without a commit.
        public var dayCount = 0
        /// The commit that changed the most lines, once they're counted.
        public var biggestCommit: Int?
        /// The day with the most commits, as an index into `days`.
        public var busiestDay: Int?
        /// The branch with the most commits, as an index into `branches`.
        public var longestBranch: Int?
        public var longestBranchCommits = 0
        /// The commit made latest in the day, where a day ends at 5 in the
        /// morning, so that 4:10 is later than 11:50 the evening before.
        public var latestCommit: Int?
        /// Whether that commit was made after a normal person's bedtime.
        public var latestIsAtNight = false
        /// How many commits were made in each hour of the day, from midnight.
        public var commitsByHour = [Int](repeating: 0, count: 24)
    }

    /// When a day ends, for working out which commit was made latest in it.
    private static let dayEndsAtMinute = 5 * 60
    /// From this hour on, a commit counts as made at night.
    private static let nightStartsAtHour = 22

    /// Works out the highlights, with days and hours in `calendar`.
    public func highlights(in calendar: Calendar = .current) -> Highlights {
        var highlights = Highlights()
        guard let firstCommit = commits.first, let lastCommit = commits.last else { return highlights }
        func day(of time: Int64) -> Date {
            calendar.startOfDay(for: Date(timeIntervalSince1970: Double(time)))
        }
        func daysBetween(_ start: Date, _ end: Date) -> Int {
            calendar.dateComponents([.day], from: start, to: end).day ?? 0
        }
        let firstDay = day(of: firstCommit.commitTime)
        highlights.dayCount = daysBetween(firstDay, day(of: lastCommit.commitTime)) + 1

        var commitsOnBranch = [Int](repeating: 0, count: branches.count)
        var mostLines = 0
        var latestMinutes = -1
        var latestHour = 0
        var dayStart = Double.infinity
        var dayEnd = -Double.infinity
        for (step, commit) in commits.enumerated() {
            let date = Double(commit.commitTime)
            // Most commits are on the same day as the one before, and asking
            // the calendar about each would be most of the time this takes.
            if date < dayStart || date >= dayEnd {
                let start = day(of: commit.commitTime)
                dayStart = start.timeIntervalSince1970
                dayEnd = (calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)).timeIntervalSince1970
                highlights.days.append(Highlights.Day(first: step, commits: 0, start: start, number: max(1, daysBetween(firstDay, start) + 1)))
            }
            highlights.days[highlights.days.count - 1].commits += 1
            commitsOnBranch[commit.branch] += 1

            let minutes = Int(date - dayStart) / 60
            let hour = min(23, minutes / 60)
            highlights.commitsByHour[hour] += 1
            let intoTheDay = (minutes - Self.dayEndsAtMinute + 24 * 60) % (24 * 60)
            if intoTheDay > latestMinutes {
                latestMinutes = intoTheDay
                latestHour = hour
                highlights.latestCommit = step
            }

            let lines = commit.lines.added + commit.lines.removed
            if lines > mostLines {
                mostLines = lines
                highlights.biggestCommit = step
            }
        }
        highlights.latestIsAtNight = latestHour >= Self.nightStartsAtHour || latestHour < Self.dayEndsAtMinute / 60

        if highlights.days.count > 1,
           let busiest = highlights.days.indices.max(by: { highlights.days[$0].commits < highlights.days[$1].commits }),
           highlights.days[busiest].commits > 1 {
            // The first of any that tie, since `max` keeps the last one it finds.
            let most = highlights.days[busiest].commits
            highlights.busiestDay = highlights.days.firstIndex { $0.commits == most }
        }
        if let most = commitsOnBranch.dropFirst().max(), most > 1 {
            highlights.longestBranch = commitsOnBranch.dropFirst().firstIndex(of: most)
            highlights.longestBranchCommits = most
        }
        return highlights
    }
}
