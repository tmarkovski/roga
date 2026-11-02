import AppKit
import HistoryUI
import SwiftUI

/// Places the AppKit commit list in SwiftUI (decision 7). The list reads
/// rows from the model itself, and SwiftUI only tells it when history or the
/// selected row has changed.
struct CommitList: NSViewRepresentable {
    let model: RepositoryModel
    /// The model's history version, so that SwiftUI updates the list when it
    /// changes.
    let version: Int
    /// The model's selected row, which is set from outside the list when a
    /// new history puts the commit in another row, or when the commit panel
    /// goes to a parent.
    let selectedRow: Int?

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.controller.scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.show(version, selecting: selectedRow)
    }

    final class Coordinator {
        let controller: CommitTableController
        private var shownVersion: Int?

        init(model: RepositoryModel) {
            controller = CommitTableController(source: CommitTableController.Source(
                count: { model.rowCount },
                content: { model.rowContent($0) },
                loadText: { await model.loadText(for: $0) },
                selectRow: { model.selectRow($0) }
            ))
        }

        func show(_ version: Int, selecting row: Int?) {
            if version != shownVersion {
                shownVersion = version
                controller.reloadData()
            }
            controller.select(row: row)
        }
    }
}
