import Foundation

/// Measures the time between successive calls to `lap()`.
struct LapTimer {
    private(set) var start = ContinuousClock.now
    private var last = ContinuousClock.now

    var total: Duration { ContinuousClock.now - start }

    mutating func lap() -> Duration {
        let now = ContinuousClock.now
        defer { last = now }
        return now - last
    }
}

extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}

func peakMemory() -> (process: Int, children: Int) {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let process = Int(usage.ru_maxrss)
    getrusage(RUSAGE_CHILDREN, &usage)
    return (process, Int(usage.ru_maxrss))
}

/// Collects named timings across runs and prints the minimum and median of each.
struct Report {
    let title: String
    private var names: [String] = []
    private var samples: [String: [Duration]] = [:]
    private var notes: [String] = []

    init(_ title: String) { self.title = title }

    mutating func record(_ name: String, _ duration: Duration) {
        if samples[name] == nil { names.append(name) }
        samples[name, default: []].append(duration)
    }

    mutating func note(_ text: String) {
        if !notes.contains(text) { notes.append(text) }
    }

    func print() {
        Swift.print("== \(title)")
        for note in notes { Swift.print("   \(note)") }
        let width = names.map(\.count).max() ?? 0
        for name in names {
            let sorted = samples[name]!.sorted()
            let median = sorted[sorted.count / 2]
            let label = name.padding(toLength: width, withPad: " ", startingAt: 0)
            Swift.print(String(format: "   %@  min %9.1f ms   median %9.1f ms   (%d runs)",
                               label, sorted[0].milliseconds, median.milliseconds, sorted.count))
        }
        let memory = peakMemory()
        Swift.print(String(format: "   peak memory: benchmark %.0f MB, git child processes %.0f MB",
                           Double(memory.process) / 1_048_576, Double(memory.children) / 1_048_576))
        Swift.print()
    }
}
