import AppKit
import Foundation
import HistoryUI
import Testing

/// How the commit list reports its selection. Only what the user does is
/// reported, so that history loading again can't change what's selected.
@Suite(.timeLimit(.minutes(1)))
struct CommitTableControllerTests {
    /// A list with rows, which records the selections it reports.
    final class List {
        var count: Int
        var reported: [Int?] = []
        private(set) lazy var controller = CommitTableController(source: CommitTableController.Source(
            count: { [unowned self] in count },
            content: { _ in CommitRowContent(shortID: "") },
            loadText: { _ in [] },
            selectRow: { [unowned self] in reported.append($0) }
        ))

        init(count: Int) {
            self.count = count
            controller.reloadData()
        }

        var table: NSTableView { controller.scrollView.documentView as! NSTableView }
    }

    @Test func reportsWhatTheUserSelects() {
        let list = List(count: 10)
        // What a click or an arrow key ends up doing.
        list.table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        list.table.deselectAll(nil)
        #expect(list.reported == [3, nil])
    }

    @Test func doesntReportASelectionFromOutside() {
        let list = List(count: 10)
        list.controller.select(row: 4)
        #expect(list.controller.selectedRow == 4)
        list.controller.select(row: nil)
        #expect(list.controller.selectedRow == nil)
        #expect(list.reported.isEmpty)
    }

    @Test func doesntReportALostSelectionWhenRowsGoAway() {
        // The first rows of a new history replace all of an old one.
        let list = List(count: 10)
        list.controller.select(row: 8)
        list.count = 5
        list.controller.reloadData()
        #expect(list.reported.isEmpty)
        list.controller.select(row: 2)
        #expect(list.controller.selectedRow == 2)
        #expect(list.reported.isEmpty)
    }

    @Test func reportsAgainAfterChangingTheSelection() {
        let list = List(count: 10)
        list.controller.select(row: 1)
        list.controller.reloadData()
        list.table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        #expect(list.reported == [2])
    }
}
