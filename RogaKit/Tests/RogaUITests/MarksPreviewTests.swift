import AppKit
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

    /// In the sidebar's width, as both Settings and setup's Hooks screen
    /// draw it, each worktree has room for its whole second line and how long,
    /// which is what says what its mark means where there are no lines out
    /// to the meanings.
    @Test func everyWorktreesLineFitsWhole() {
        // The panel's inset either side, the room the line from the
        // repository takes, then the row's own padding and the room its line
        // leaves before how long, as SidebarRow lays them out.
        let room = MarksPreview.width - 2 * MarksPreview.inset - WorktreeConnector.textIndent - 10 - 4 - 7
        let font = NSFont.systemFont(ofSize: 13)
        func width(_ words: String) -> CGFloat {
            (words as NSString).size(withAttributes: [.font: font]).width
        }
        for sample in MarksPreview.samples {
            let parts = sample.summary.rowParts(now: MarksPreview.date)
            let needed = width(parts.words) + (parts.time.map { 8 + width($0) } ?? 0)
            #expect(needed <= room, "\(parts.words) needs \(needed) of \(room)")
        }
    }
}
