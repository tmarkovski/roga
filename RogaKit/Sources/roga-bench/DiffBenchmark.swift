import AppKit
import Darwin
import DiffUI
import Foundation
import GitCore
import QuartzCore

/// Measures the diff view with a generated patch, which needs no repository:
/// building its text, showing it, and then scrolling steadily and jumping. Each
/// step is timed from moving the text until the window has drawn, on the main
/// thread, so the times don't depend on the screen's refresh rate.
struct DiffBenchmark {
    var lines = 40_325
    var lineLength = 60
    var seconds = 5.0
    var speed = 6000.0
    var jumps = 40

    init(arguments: [String]) throws {
        var arguments = arguments[...]
        while let option = arguments.popFirst() {
            guard let value = arguments.popFirst().flatMap({ Int($0) }) else { throw UsageError(description: "\(option) needs a number") }
            switch option {
            case "--lines": lines = value
            case "--line-length": lineLength = value
            case "--jumps": jumps = value
            default: throw UsageError(description: "Unknown option \(option)")
            }
        }
    }

    /// Hunks of removed lines and added lines with context around them. Tabs
    /// and hex numbers, like the largest file in the prototype's test, with a
    /// number on each changed line that differs from the other side.
    private func patch() throws -> FilePatch {
        var text = "diff --git a/table.c b/table.c\n--- a/table.c\n+++ b/table.c\n"
        text.reserveCapacity(lines * (lineLength + 2))
        let padding = String(repeating: "0x1f, ", count: max(0, lineLength - 8) / 6)
        var old = 1
        var written = 0
        while written < lines {
            let changed = 40
            text += "@@ -\(old),\(changed + 6) +\(old),\(changed + 6) @@ static const u32 table[] = {\n"
            for _ in 0..<3 { text += " \t\(padding)\n" }
            for index in 0..<changed { text += "-\t\(padding)0x\(String(index, radix: 16)),\n" }
            for index in 0..<changed { text += "+\t\(padding)0x\(String(index + changed, radix: 16)),\n" }
            for _ in 0..<3 { text += " \t\(padding)\n" }
            old += changed + 6
            written += changed * 2 + 7
        }
        return try PatchParser.parse(Array(text.utf8))
    }

    @MainActor func run() async throws {
        let clock = ContinuousClock()
        let patch = try self.patch()
        print("\(patch.lines.count) lines, \(patch.bytes.count >> 10) KB of patch text")

        var start = clock.now
        _ = await DiffTextBuilder.document(for: patch)
        print("Building the text: \(clock.now - start)")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let controller = DiffTextController()
        window.contentView = controller.view
        // It doesn't take the keyboard from whatever the user is doing.
        window.orderFrontRegardless()
        window.displayIfNeeded()

        // The first text a process draws costs extra, so this measures the second too.
        for attempt in ["First", "Second"] {
            let shown = await DiffTextBuilder.document(for: patch)
            start = clock.now
            controller.show(shown)
            let set = clock.now - start
            window.displayIfNeeded()
            CATransaction.flush()
            print("\(attempt) time showing it: \(set) to set the text, \(clock.now - start) to draw it")
        }

        let clip = controller.scrollView.contentView
        guard let text = controller.scrollView.documentView else { throw UsageError(description: "The scroll view has no text") }

        func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        func report(_ title: String, _ times: [Double]) {
            let sorted = times.sorted()
            guard let longest = sorted.last else { return }
            let median = sorted[sorted.count / 2]
            let high = sorted[min(sorted.count - 1, sorted.count * 99 / 100)]
            print("\(title): \(times.count) steps, median \(String(format: "%.1f", median)) ms, 99th percentile \(String(format: "%.1f", high)) ms, longest \(String(format: "%.1f", longest)) ms")
        }
        // Steps come at the rate of a 60 Hz screen, because going faster than
        // that makes the window server hold back the commits.
        func move(to y: Double) async -> Double {
            let start = clock.now
            clip.scroll(to: NSPoint(x: 0, y: y))
            controller.scrollView.reflectScrolledClipView(clip)
            window.displayIfNeeded()
            CATransaction.flush()
            let time = clock.now - start
            try? await clock.sleep(until: start + .milliseconds(16))
            return milliseconds(time)
        }

        func footprint() -> Int {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
            }
            return result == 0 ? Int(info.ri_phys_footprint >> 20) : 0
        }
        print("Memory: \(footprint()) MB")
        print("Height at first: \(Int(text.frame.height)), and every row would take \(Int(Double(patch.lines.count) * 17))")

        var steady: [Double] = []
        let step = speed / 60
        var y = 0.0
        for _ in 0..<Int(seconds * 60) {
            y += step
            let bottom = max(0, text.frame.height - clip.bounds.height)
            steady.append(await move(to: min(y, bottom)))
        }
        report("Scrolling steadily", steady)

        var jumped: [Double] = []
        var random: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<jumps {
            // A SplitMix64 step, so that every run jumps to the same places.
            random &+= 0x9E37_79B9_7F4A_7C15
            var z = random
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            let bottom = max(0, text.frame.height - clip.bounds.height)
            jumped.append(await move(to: Double(z >> 11) / Double(1 << 53) * bottom))
        }
        report("Jumping", jumped)
        print("Height after that: \(Int(text.frame.height))")

        let bottom = max(0, text.frame.height - clip.bounds.height)
        print("Going to the end: \(await move(to: bottom)) ms")
        print("Memory: \(footprint()) MB")
        window.close()
    }
}
