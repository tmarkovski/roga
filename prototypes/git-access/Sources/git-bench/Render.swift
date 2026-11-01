import AppKit
import ArgumentParser
import QuartzCore
import SwiftUI

enum RenderEngine: String, ExpressibleByArgument, CaseIterable {
    case table
    case list
    case lazyStack = "lazy-stack"
}

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render",
        abstract: "Open a window that shows the history and measure how smoothly it scrolls."
    )

    @OptionGroup var common: CommonOptions

    @Option(help: "Which view draws the rows.")
    var engine: RenderEngine = .table

    @Option(help: "Show only the first this many commits.")
    var rows: Int?

    @Option(help: "Steady scrolling speed, in points per second.")
    var speed: Double = 6000

    @Option(help: "How long to scroll steadily, in seconds.")
    var seconds: Double = 5

    @Option(help: "How many jumps to random positions to make.")
    var jumps: Int = 20

    func run() throws {
        let engine = engine
        let settings = ScrollSettings(speed: speed, seconds: seconds, jumps: jumps)
        try MainActor.assumeIsolated {
            var timer = LapTimer()
            let model = try HistoryModel(repo: common.repoPath, limit: rows)
            let loadTime = timer.lap()

            // Give up if the view never shows anything, rather than hanging forever.
            let title = "render, \(engine.rawValue), \(model.count) rows"
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                print("== \(title)\n   gave up: nothing finished within 300 s\n")
                Darwin.exit(2)
            }

            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let window = NSWindow(
                contentRect: NSRect(x: 120, y: 120, width: 1200, height: 800),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "yaga prototype: \(engine.rawValue)"
            // Each view inserts new commits at the top, as it would after a fetch, and selects a
            // row in its own way.
            let actions: ViewActions
            switch engine {
            case .table:
                let tableEngine = TableEngine(model: model)
                window.contentView = tableEngine.makeView()
                actions = ViewActions(insertCommits: { tableEngine.prependCommits(10) },
                                      selectRow: { tableEngine.select(row: $0) })
            case .list:
                window.contentView = NSHostingView(rootView: ListHistoryView(model: model))
                actions = ViewActions(insertCommits: { model.prependCommits(10) },
                                      selectRow: { model.selection = model.ids[$0] })
            case .lazyStack:
                window.contentView = NSHostingView(rootView: LazyStackHistoryView(model: model))
                actions = ViewActions(insertCommits: { model.prependCommits(10) },
                                      selectRow: { model.selection = model.ids[$0] })
            }

            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical], reason: "Measuring scrolling")
            let driver = ScrollDriver(window: window, settings: settings, actions: actions) { results in
                ProcessInfo.processInfo.endActivity(activity)
                results.print(title: title,
                              setup: "history loaded in \(Int(loadTime.milliseconds)) ms before the window opened",
                              settings: settings)
                Darwin.exit(0)
            }
            window.makeKeyAndOrderFront(nil)
            app.activate()
            driver.start()
            app.run()
        }
    }
}

/// Set by whichever view draws its first row, so the driver knows content is on screen.
nonisolated(unsafe) var firstRowDrawn = false

/// Counts rows drawn, to confirm that the driver really scrolled the view.
nonisolated(unsafe) var rowsDrawn = 0

enum RowMetrics {
    static let height: CGFloat = 22
    static let laneSpacing: CGFloat = 10
    static let maxLanes = 20
    static let graphWidth = laneSpacing * CGFloat(maxLanes) + 10
    static func laneX(_ lane: Int) -> CGFloat { 10 + CGFloat(lane) * laneSpacing }
}

/// The history to draw: real order and lanes from the commit-graph file, with generated text so
/// that the measurement covers drawing only.
///
/// Each row has a stable ID, its commit-graph position, the way the app would identify commits.
/// Commits inserted at the top get negative IDs.
@MainActor
@Observable
final class HistoryModel {
    private(set) var ids: [Int32]
    private(set) var inserted = 0
    var selection: Int32?
    var count: Int { ids.count }

    private let graph: CommitGraph
    private let rows: [Int32]
    private let layout: GraphLayout
    private let formatter: DateFormatter

    private static let areas = ["net", "drm/amd", "mm", "fs/ext4", "sched", "usb", "arm64", "kvm", "btrfs", "media"]
    private static let verbs = ["fix", "add", "remove", "rework", "simplify", "document", "avoid", "convert"]
    private static let objects = [
        "a use-after-free in the error path", "support for the new controller",
        "a race when tearing down queues", "the reference count on reset",
        "dead code left after the last cleanup", "locking around the device list",
        "a warning when building with clang",
    ]
    private static let authors = [
        "Maria Lindqvist", "Kenji Watanabe", "Oluwaseun Adeyemi", "Priya Raman", "Tomás Herrera",
        "Anna Kowalczyk", "Wei Zhang", "Lars Johansen", "Fatima Haddad", "Sam O'Connell",
    ]

    init(repo: String, limit: Int?) throws {
        let lines = try runGit(["rev-parse", "--absolute-git-dir", "HEAD"], in: repo)
            .split(separator: "\n").map(String.init)
        graph = try CommitGraph(path: lines[0] + "/objects/info/commit-graph")
        guard let head = OID(hex: lines[1]), let headPosition = graph.position(of: head) else {
            throw BenchError("HEAD isn't in the commit-graph")
        }
        let (allRows, rowOf) = graph.dateOrder(from: headPosition)
        rows = limit.map { Array(allRows.prefix($0)) } ?? allRows
        ids = rows
        var scratch: [Int32] = []
        let rows = rows
        let graph = graph
        layout = layoutGraph(rowCount: rows.count, recordWidths: true) { row, out in
            scratch.removeAll(keepingCapacity: true)
            graph.parents(of: rows[row], into: &scratch)
            for parent in scratch where rowOf[Int(parent)] >= 0 && Int(rowOf[Int(parent)]) < rows.count {
                out.append(rowOf[Int(parent)])
            }
        }
        formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
    }

    /// Adds commits at the top, as a fetch would.
    func prependCommits(_ count: Int) {
        let newIDs = (0..<count).map { -Int32(inserted + count - $0) }
        ids.insert(contentsOf: newIDs, at: 0)
        inserted += count
    }

    /// The commit's lane and how many lanes to draw, capped at what fits.
    func lanes(_ row: Int) -> (column: Int, width: Int) {
        let base = row - inserted
        guard base >= 0 else { return (0, 1) }
        let width = min(Int(layout.widths[base]), RowMetrics.maxLanes)
        return (min(Int(layout.columns[base]), RowMetrics.maxLanes - 1), width)
    }

    func subject(_ row: Int) -> String {
        let base = row - inserted
        guard base >= 0 else { return "Merge branch 'fixes' into master (new commit \(-base))" }
        return "\(Self.areas[base % 10]): \(Self.verbs[(base / 10) % 8]) \(Self.objects[(base / 80) % 7])"
    }

    func author(_ row: Int) -> String { Self.authors[(abs(row - inserted) / 3) % Self.authors.count] }

    func date(_ row: Int) -> String {
        let base = row - inserted
        guard base >= 0 else { return "Just now" }
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(graph.commitTime(rows[base]))))
    }
}

struct ScrollSettings {
    var speed: Double
    var seconds: Double
    var jumps: Int
    var inserts = 5
    var selections = 5
}

struct ViewActions {
    var insertCommits: @MainActor () -> Void
    var selectRow: @MainActor (Int) -> Void
    /// Whether the view has put content on screen yet.
    var contentReady: @MainActor () -> Bool = { firstRowDrawn }
}

struct ScrollResults {
    var firstContent: Double = 0
    var nominalFrame: Double = 1.0 / 60
    var contentHeight: Double = 0
    var frameIntervals: [Double] = []
    var jumpLatencies: [Double] = []
    var insertLatencies: [Double] = []
    var selectLatencies: [Double] = []

    func print(title: String, setup: String, settings: ScrollSettings) {
        let intervals = frameIntervals.sorted()
        let hitches = frameIntervals.filter { $0 > nominalFrame * 1.5 }
        let hitchTime = hitches.reduce(0) { $0 + ($1 - nominalFrame) } / settings.seconds
        let jumps = jumpLatencies.sorted()
        func ms(_ seconds: Double) -> String { String(format: "%.1f ms", seconds * 1000) }

        Swift.print("== \(title)")
        Swift.print("   \(setup)")
        Swift.print("   first rows on screen: \(ms(firstContent)) after the window opened")
        Swift.print(String(format: "   steady scroll at %.0f pt/s for %.0f s: %d frames at %.0f Hz, %d hitches, hitch time %.1f ms/s",
                           settings.speed, settings.seconds, frameIntervals.count, 1 / nominalFrame,
                           hitches.count, hitchTime * 1000))
        if !intervals.isEmpty {
            Swift.print("   frame time: median \(ms(intervals[intervals.count / 2])), 95th percentile \(ms(intervals[intervals.count * 95 / 100])), longest \(ms(intervals.last!))")
        }
        if !jumps.isEmpty {
            Swift.print("   \(jumps.count) jumps to random positions: median \(ms(jumps[jumps.count / 2])), longest \(ms(jumps.last!)) until the next frame")
        }
        let inserts = insertLatencies.sorted()
        if !inserts.isEmpty {
            Swift.print("   \(inserts.count) inserts of 10 commits at the top: median \(ms(inserts[inserts.count / 2])), longest \(ms(inserts.last!)) until the next frame")
        }
        let selections = selectLatencies.sorted()
        if !selections.isEmpty {
            Swift.print("   \(selections.count) selections of a visible row: median \(ms(selections[selections.count / 2])), longest \(ms(selections.last!)) until the next frame")
        }
        if rowsDrawn > 0 {
            Swift.print(String(format: "   %d rows drawn in all, scrolled content %.0f pt tall", rowsDrawn, contentHeight))
        } else {
            Swift.print(String(format: "   scrolled content %.0f pt tall when the first rows appeared", contentHeight))
        }
        Swift.print(String(format: "   peak memory: %.0f MB\n", Double(peakMemory().process) / 1_048_576))
    }
}

/// Drives scrolling from the display link and records how long each frame takes.
///
/// It scrolls the underlying `NSScrollView` directly, the way a trackpad does, so every view is
/// measured the same way.
@MainActor
final class ScrollDriver: NSObject {
    private enum Phase { case waitingForContent, settling, scrolling, jumping, inserting, selecting, done }

    private let window: NSWindow
    private let settings: ScrollSettings
    private let actions: ViewActions
    private let finish: (ScrollResults) -> Void
    private var actionIssuedAt: CFTimeInterval?
    private var ticksToWait = 0
    private var phase = Phase.waitingForContent
    private var results = ScrollResults()
    private var scrollView: NSScrollView?
    private var shownAt: CFTimeInterval = 0
    private var phaseStart: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var jumpIssuedAt: CFTimeInterval?
    private var random: UInt64 = 0x9E37_79B9_7F4A_7C15

    init(window: NSWindow, settings: ScrollSettings, actions: ViewActions,
         finish: @escaping (ScrollResults) -> Void) {
        self.window = window
        self.settings = settings
        self.actions = actions
        self.finish = finish
    }

    func start() {
        shownAt = CACurrentMediaTime()
        window.contentView!.displayLink(target: self, selector: #selector(tick(_:))).add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        switch phase {
        case .waitingForContent:
            guard actions.contentReady() else { return }
            results.firstContent = now - shownAt
            scrollView = Self.largestScrollView(in: window.contentView!)
            guard scrollView != nil else {
                print("   no scroll view found")
                exit(3)
            }
            results.contentHeight = Double(scrollView?.documentView?.frame.height ?? 0)
            phase = .settling
            phaseStart = now
        case .settling:
            if now - phaseStart >= 1 {
                phase = .scrolling
                phaseStart = now
                lastTick = now
                if link.targetTimestamp > link.timestamp { results.nominalFrame = link.targetTimestamp - link.timestamp }
            }
        case .scrolling:
            results.frameIntervals.append(now - lastTick)
            lastTick = now
            let elapsed = now - phaseStart
            scroll(toOffset: elapsed * settings.speed)
            if elapsed >= settings.seconds { phase = .jumping }
        case .jumping:
            if let issued = jumpIssuedAt { results.jumpLatencies.append(now - issued) }
            if results.jumpLatencies.count >= settings.jumps {
                phase = .inserting
                ticksToWait = 30
                return
            }
            scroll(toFraction: nextRandom())
            jumpIssuedAt = CACurrentMediaTime()
        case .inserting:
            if repeatAction(now: now, times: settings.inserts, into: &results.insertLatencies, action: actions.insertCommits) {
                phase = .selecting
                ticksToWait = 30
            }
        case .selecting:
            let row = firstVisibleRow() + 5 + results.selectLatencies.count
            if repeatAction(now: now, times: settings.selections, into: &results.selectLatencies,
                            action: { self.actions.selectRow(row) }) {
                phase = .done
                link.invalidate()
                finish(results)
            }
        case .done:
            break
        }
    }

    /// Performs `action` every 30 frames and records the time until the frame after each one.
    /// Returns true once it has been performed `times` times.
    private func repeatAction(now: CFTimeInterval, times: Int, into latencies: inout [Double],
                              action: () -> Void) -> Bool {
        if let issued = actionIssuedAt {
            latencies.append(now - issued)
            actionIssuedAt = nil
            ticksToWait = 30
        }
        if latencies.count >= times { return true }
        if ticksToWait > 0 {
            ticksToWait -= 1
            return false
        }
        actionIssuedAt = CACurrentMediaTime()
        action()
        return false
    }

    private func firstVisibleRow() -> Int {
        guard let scrollView, let document = scrollView.documentView else { return 0 }
        let clip = scrollView.contentView.bounds
        let offset = document.isFlipped ? clip.minY : document.frame.height - clip.maxY
        return max(0, Int(offset / RowMetrics.height))
    }

    private func scroll(toOffset offset: Double) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxOffset = max(0, document.frame.height - clip.bounds.height)
        let clamped = min(offset, maxOffset)
        let y = document.isFlipped ? clamped : maxOffset - clamped
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func scroll(toFraction fraction: Double) {
        guard let scrollView, let document = scrollView.documentView else { return }
        scroll(toOffset: fraction * max(0, document.frame.height - scrollView.contentView.bounds.height))
    }

    /// A SplitMix64 step, so every run jumps to the same positions.
    private func nextRandom() -> Double {
        random &+= 0x9E37_79B9_7F4A_7C15
        var z = random
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }

    private static func largestScrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        var stack = [view]
        while let current = stack.popLast() {
            if let scroll = current as? NSScrollView,
               (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) {
                best = scroll
            }
            stack.append(contentsOf: current.subviews)
        }
        return best
    }
}
