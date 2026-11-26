import GitCore
import SwiftUI

/// Where the lists of a worktree's files are in the scroll they share, so that
/// each list's heading stays in view while its files are scrolled away
/// (decision 115). A heading whose place has scrolled up past the top stays at
/// the top, under the headings before it, and one whose place is below the
/// bottom stays at the bottom, over the headings after it. Every heading is the
/// same height, and so is every row (`FileRows.rowHeight`), so where a heading
/// or a row sits follows from where its list's rows start.
///
/// Only the headings read it, so that scrolling draws them again and nothing
/// else.
@MainActor @Observable
final class StuckHeadings {
    /// Where a list is among the lists that show.
    struct Place: Equatable {
        let index: Int
        let count: Int
    }

    /// Where each list's rows start, in the scroll's visible frame.
    var rowsTops: [WorktreeChanges.Group: Double] = [:]
    /// How tall the scroll is.
    var height = 0.0

    /// The coordinate space of the scroll's visible frame.
    static let space = "uncommitted files"
    /// How tall a heading's title and buttons are.
    static let titleHeight = 20.0
    /// The room above a heading's title, which sets it apart from the rows of
    /// the list before it.
    static let aboveTitle = 10.0
    /// The room under a heading's title.
    static let belowTitle = 6.0
    /// How tall a heading is.
    static var headingHeight: Double { titleHeight + aboveTitle + belowTitle }

    /// What a list's heading is known by, for scrolling to it.
    static func headingID(_ group: WorktreeChanges.Group) -> String {
        "heading of \(group)"
    }

    /// How far a list's heading is drawn from its place to stay in view: down
    /// while its place is above the top, and up while it's below the bottom. In
    /// a scroll too short for every heading, the ones at the top win.
    func shift(of group: WorktreeChanges.Group, at place: Place) -> Double {
        guard let rowsTop = rowsTops[group], height > 0 else { return 0 }
        let heading = Self.headingHeight
        let top = rowsTop - heading
        let highest = Double(place.index) * heading
        let lowest = max(highest, height - Double(place.count - place.index) * heading)
        return min(max(top, highest), lowest) - top
    }

    /// Scrolls so that a list's heading is in its place, right under the
    /// headings before it, with its first files under it.
    func scroll(_ scroller: ScrollViewProxy, to group: WorktreeChanges.Group, at place: Place) {
        scroller.scrollTo(Self.headingID(group), anchor: anchor(top: Double(place.index) * Self.headingHeight, of: Self.headingHeight))
    }

    /// Scrolls the least that brings a row clear of the headings that can be
    /// stuck at the edges while it's in view: its own list's and those before it
    /// at the top, and those after it at the bottom.
    ///
    /// - Parameter row: Where the row is in its list, or nil when it isn't there.
    func scroll(_ scroller: ScrollViewProxy, toRow id: FileRow.ID, at row: Int?, of group: WorktreeChanges.Group, place: Place?) {
        guard let row, let place, let rowsTop = rowsTops[group] else {
            scroller.scrollTo(id)
            return
        }
        let rowHeight = FileRows.rowHeight
        let top = rowsTop + Double(row) * rowHeight
        let highest = Double(place.index + 1) * Self.headingHeight
        let lowest = height - Double(place.count - place.index - 1) * Self.headingHeight
        if top < highest {
            scroller.scrollTo(id, anchor: anchor(top: highest, of: rowHeight))
        } else if top + rowHeight > lowest {
            scroller.scrollTo(id, anchor: anchor(top: lowest - rowHeight, of: rowHeight))
        }
    }

    /// Where a row goes so that it's right under the headings that can be stuck
    /// above it, for a list that has just changed, whose rows aren't where they
    /// were.
    func anchorUnderHeadings(at place: Place) -> UnitPoint {
        anchor(top: Double(place.index + 1) * Self.headingHeight, of: FileRows.rowHeight)
    }

    /// The anchor that puts the top of something this tall at a height in the
    /// scroll. Scrolling lines up the same point of each, so the point is as far
    /// down the thing as the height is down the room the scroll has for it.
    private func anchor(top: Double, of itemHeight: Double) -> UnitPoint {
        let room = height - itemHeight
        guard room > 0 else { return .top }
        return UnitPoint(x: 0, y: min(max(top / room, 0), 1))
    }
}

/// A list's heading, which stays in view at the top or the bottom of the files
/// while its own are scrolled away. While it's stuck at an edge, a line parts it
/// from the files that go under it, and clicking it, away from its buttons,
/// scrolls to its files.
struct StuckHeading<Content: View>: View {
    let headings: StuckHeadings
    let group: WorktreeChanges.Group
    let place: StuckHeadings.Place
    /// Scrolls to the list's files.
    let reveal: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        let shift = headings.shift(of: group, at: place)
        // Within half a point of its place, it's where it belongs.
        let isAtTop = shift > 0.5
        let isAtBottom = shift < -0.5
        content
            .background(Palette.surface)
            .overlay(alignment: isAtBottom ? .top : .bottom) {
                Rectangle()
                    .fill(Palette.separator)
                    .frame(height: 1)
                    .opacity(isAtTop || isAtBottom ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isAtTop || isAtBottom { reveal() }
            }
            .offset(y: shift)
            .id(StuckHeadings.headingID(group))
            // Over the rows that scroll under it.
            .zIndex(1)
    }
}
