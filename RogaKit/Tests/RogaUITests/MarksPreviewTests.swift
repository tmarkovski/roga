import Foundation
import Testing
@testable import AgentHooks
@testable import RogaUI

/// The piece of the sidebar that Settings › Agents and setup's Hooks screen
/// show to say what the marks mean.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MarksPreviewTests {
    @Test func thePictureHasEachMarkOnce() {
        let states = MarksPreview.samples.map(\.summary.state)
        #expect(states == [.working, .waiting(.permission), .finished])
        #expect(MarksPreview.samples.map(\.title) == ["Working", "Waiting", "Finished"])
        // One row is selected, as one always is in the sidebar, and the last
        // one ends the line from the repository.
        #expect(MarksPreview.samples.count { $0.isSelected } == 1)
        #expect(MarksPreview.samples.map(\.isLast) == [false, false, true])
    }

    /// The rows count how long from the picture's own moment, so they say the
    /// same thing however long Settings stays open.
    @Test func theSecondLinesStandStill() {
        let parts = MarksPreview.samples.map { $0.summary.rowParts(now: MarksPreview.date) }
        #expect(parts.map(\.words) == ["Editing LoginView.swift", "Approval required: git push", "Claude Code finished"])
        #expect(parts.map(\.time) == ["2 min", "1 min", nil])
    }
}
