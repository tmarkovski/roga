import AppKit
import CommitGraph
import GitCore
import HistoryUI
import SwiftUI
import Testing
@testable import RogaUI

/// The cutout of the window under Theme and Colors in Settings › Appearance, which
/// has to show what a color theme colors: several lanes, each kind of branch, what
/// was added and removed, and a diff's tints.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ThemePreviewTests {
    @Test func theSampleHistoryLaysOutAsFourLanes() throws {
        let rows = try ThemeSample.rows(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(rows.count == ThemeSample.shownRows)
        #expect(ThemeSample.rows.count == ThemeSample.shownRows)

        // Four lanes side by side, each in its own color, and no row wider than
        // that, so the graph stays a small part of the row.
        let lanes = rows.compactMap(\.lanes)
        #expect(lanes.count == rows.count)
        #expect(Set(lanes.map(\.color)).count == 4)
        #expect(lanes.map(\.width).max() == 4)
        // The lines run on down past the last row, as in a cutout of a longer history.
        let leaving = try #require(lanes.last).lines.filter { line in
            if case .column = line.bottom { true } else { false }
        }
        #expect(leaving.count == 4)
    }

    @Test func theSampleHistoryHasEachKindOfBadge() throws {
        let rows = ThemeSample.rows
        let kinds = rows.flatMap(\.badges).map(\.kind)
        #expect(Set(kinds) == [.currentBranch, .branch, .remoteBranch, .tag])
        // The commit `HEAD` is on is the selected one, so the ring and the badge
        // show on a selected row's gray, which is where they're hardest to read.
        let current = try #require(rows.firstIndex { $0.badges.contains { $0.kind == .currentBranch } })
        #expect(current == ThemeSample.selectedRow)
        // A branch that's in sync with its upstream has a cloud.
        #expect(rows.flatMap(\.badges).contains { $0.upstream != nil })
        #expect(rows.allSatisfy { $0.subject?.isEmpty == false && $0.date?.isEmpty == false && $0.shortID.count == 8 })
    }

    @Test func theSampleFilesAreATreeWithEachChange() throws {
        let rows = ThemeSample.fileRows
        guard case .folder(_, let title, let isCollapsed, _) = try #require(rows.first).content else {
            Issue.record("The first row isn't a folder")
            return
        }
        #expect(title == "Sources/Badges")
        #expect(!isCollapsed)
        let files = rows.dropFirst().compactMap(\.file)
        #expect(files.count == rows.count - 1)
        #expect(rows.dropFirst().allSatisfy { $0.depth == 1 })
        #expect(Set(files.map(\.status)) == [.added, .modified, .deleted])
        #expect(files.contains { $0.path == ThemeSample.selectedPath })
    }

    @Test func theSamplePatchIsTheSelectedFilesChange() throws {
        let patch = ThemeSample.patch
        #expect(patch.lines.map(\.kind) == [.hunkHeader, .context, .removed, .added, .added, .context])
        // Its counts are the ones the file's row says.
        let file = try #require(ThemeSample.files.first { $0.path == ThemeSample.selectedPath })
        #expect(file.lines?.added == patch.lines.count { $0.kind == .added })
        #expect(file.lines?.removed == patch.lines.count { $0.kind == .removed })
        // No line is longer than the diff has room for beside the files.
        #expect(patch.lines.allSatisfy { $0.text.count <= 40 })
    }

    /// The preview is as tall as its rows and takes whatever width it's given, so
    /// that the page under it doesn't move as the theme changes.
    @Test func thePreviewIsAsTallAsItsRows() {
        let rows = CommitRowsPicture.height(rows: ThemeSample.shownRows)
        for width in [520.0, 607.0] {
            let host = NSHostingView(rootView: ThemePreview().frame(width: width))
            #expect(host.fittingSize == CGSize(width: width, height: 4 + rows + 1 + ThemeSample.diffHeight))
        }
    }

    /// The diff is a real text view in a scroll view, which would otherwise take
    /// the scroll wheel, so the page would stop scrolling with the pointer over it.
    @Test func thePointerGoesThroughThePreview() throws {
        let host = NSHostingView(rootView: ThemePreview().frame(width: 607))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        func all(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(all)
        }
        let views = all(host)
        let text = try #require(views.first { $0 is NSTextView })
        let rows = try #require(views.first { $0 is CommitRowsPicture })
        #expect(text.frame.height > 0)
        for view in [text, rows] {
            let middle = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: host.superview)
            let hit = host.hitTest(middle)
            // Nothing of the sample's: not the view, and nothing it's inside of.
            var above = hit
            while let current = above, current !== host {
                #expect(!(current is NSTextView) && !(current is NSScrollView) && !(current is CommitRowsPicture), "\(type(of: current))")
                above = current.superview
            }
        }
    }

    @Test func aPictureOfCommitRowsTakesNoClicks() {
        let picture = CommitRowsPicture(rows: ThemeSample.rows, selectedRow: ThemeSample.selectedRow)
        picture.frame = NSRect(x: 0, y: 0, width: 600, height: CommitRowsPicture.height(rows: ThemeSample.shownRows))
        #expect(picture.intrinsicContentSize.height == 168)
        #expect(picture.hitTest(NSPoint(x: 100, y: 40)) == nil)
        #expect(picture.subviews.isEmpty)
    }
}
