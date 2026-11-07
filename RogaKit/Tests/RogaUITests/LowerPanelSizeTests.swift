import SwiftUI
import Testing
@testable import RogaUI

/// How tall history and the panels under it are, as the panels are dragged,
/// maximized and minimized, and what the View menu and the buttons do.
@Suite
struct LowerPanelSizeTests {
    func layout(_ size: LowerPanelSize, height: Double = 600, lowerHeight: Double = 340, upperHeightUntilDragged: Double = 0) -> PanelSplitLayout {
        PanelSplitLayout(height: height, lowerHeight: lowerHeight, upperHeightUntilDragged: upperHeightUntilDragged, size: size)
    }

    @Test func regularPanelsKeepTheirHeightWithTheLineBetween() {
        #expect(layout(.regular) == PanelSplitLayout(upper: 259, lower: 340))
    }

    @Test func regularPanelsLeaveHistoryTheRoomItHadUntilDragged() {
        #expect(layout(.regular, lowerHeight: 0, upperHeightUntilDragged: 144) == PanelSplitLayout(upper: 144, lower: 455))
    }

    @Test func regularPanelsLeaveEachOtherTheirShortest() {
        #expect(layout(.regular, lowerHeight: 560).upper == 100)
        #expect(layout(.regular, lowerHeight: 20).lower == 100)
    }

    @Test func maximizedPanelsTakeAllOfItAndHistoryNone() {
        #expect(layout(.maximized) == PanelSplitLayout(upper: 0, lower: 600))
    }

    @Test func minimizedPanelsShowOnlyTheirHeaders() {
        #expect(layout(.minimized) == PanelSplitLayout(upper: 559, lower: 40))
    }

    @Test func draggingTheLineDownPastHalfwayToTheHeaderMinimizesAndKeepsTheHeight() {
        let dragged = PanelSplitLayout.dragged(to: 69, in: 600)
        #expect(dragged.size == .minimized)
        #expect(dragged.height == nil)
    }

    @Test func draggingTheLineAboveHalfwayIsRegularAtLeastTheShortest() {
        let dragged = PanelSplitLayout.dragged(to: 70, in: 600)
        #expect(dragged.size == .regular)
        #expect(dragged.height == 100)
        #expect(PanelSplitLayout.dragged(to: 300, in: 600).height == 300)
        #expect(PanelSplitLayout.dragged(to: 590, in: 600).height == 499)
    }

    @Test func eachButtonTogglesItsOwnSize() {
        #expect(LowerPanelSize.regular.maximizeToggled == .maximized)
        #expect(LowerPanelSize.maximized.maximizeToggled == .regular)
        #expect(LowerPanelSize.minimized.maximizeToggled == .maximized)
        #expect(LowerPanelSize.regular.minimizeToggled == .minimized)
        #expect(LowerPanelSize.minimized.minimizeToggled == .regular)
        #expect(LowerPanelSize.maximized.minimizeToggled == .minimized)
    }

    @Test func theMenuGoesAStepAtATime() {
        #expect(LowerPanelSize.minimized.taller == .regular)
        #expect(LowerPanelSize.regular.taller == .maximized)
        #expect(LowerPanelSize.maximized.taller == nil)
        #expect(LowerPanelSize.maximized.shorter == .regular)
        #expect(LowerPanelSize.regular.shorter == .minimized)
        #expect(LowerPanelSize.minimized.shorter == nil)
    }

    @Test func theMenuSaysRestoreForTheStepBack() {
        #expect(LowerPanelSize.regular.tallerTitle == "Maximize Panels")
        #expect(LowerPanelSize.regular.shorterTitle == "Minimize Panels")
        #expect(LowerPanelSize.minimized.tallerTitle == "Restore Panels")
        #expect(LowerPanelSize.maximized.shorterTitle == "Restore Panels")
    }

    @Test func aButtonsTooltipShowsAShortcutOnlyWhenOneDoesTheSame() {
        #expect(LowerPanelSize.regular.shortcut(to: .maximized) == LowerPanelSize.tallerShortcut)
        #expect(LowerPanelSize.maximized.shortcut(to: .regular) == LowerPanelSize.shorterShortcut)
        #expect(LowerPanelSize.minimized.shortcut(to: .regular) == LowerPanelSize.tallerShortcut)
        #expect(LowerPanelSize.minimized.shortcut(to: .maximized) == nil)
        #expect(LowerPanelSize.maximized.shortcut(to: .minimized) == nil)
    }

    @Test func arrowsShowAsArrows() {
        #expect(LowerPanelSize.tallerShortcut.symbols == "⌃\u{2009}⌘\u{2009}↑")
        #expect(LowerPanelSize.shorterShortcut.symbols == "⌃\u{2009}⌘\u{2009}↓")
    }
}

/// Where the panels' headers end up in a real layout, with one panel whose
/// content can't get shorter than its own height.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MinimizedPanelHeadersTests {
    final class Positions {
        var leading: CGFloat?
        var trailing: CGFloat?
    }

    /// A header's title that reports how far down the window it is.
    func title(_ text: String, into position: @escaping (CGFloat) -> Void) -> some View {
        Text(text)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { position($0) }
    }

    @Test func bothHeadersShowAtTheBottomWhenOnePanelCantShrink() async throws {
        let positions = Positions()
        let height = 300.0
        let view = PanelSplit(lowerHeight: .constant(200), lowerSize: .constant(.minimized)) {
            Color.clear
        } lower: {
            PanelColumns(leadingWidth: .constant(200)) {
                Panel {
                    title("Commit") { positions.leading = $0 }
                } trailing: {
                    EmptyView()
                } content: {
                    // Like the note that asks for a commit to be selected.
                    Color.clear.frame(minHeight: 100)
                }
            } trailing: {
                Panel {
                    title("Diff") { positions.trailing = $0 }
                } trailing: {
                    EmptyView()
                } content: {
                    Color.clear
                }
            }
        }
        .frame(width: 600, height: height)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for _ in 0..<20 where positions.leading == nil || positions.trailing == nil {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let leading = try #require(positions.leading)
        let trailing = try #require(positions.trailing)
        #expect(leading == trailing)
        // Each title sits in the header, the last 40 points of the window.
        #expect(leading > height - PanelSplitLayout.headerHeight)
        #expect(leading < height - 10)
        window.contentView = nil
    }
}
