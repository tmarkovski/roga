import AppKit
import HistoryUI
import SwiftUI

/// Places the AppKit commit list in SwiftUI (decision 7). The list reads
/// rows from the model itself, and SwiftUI only tells it when history has
/// changed.
struct CommitList: NSViewRepresentable {
    let model: RepositoryModel
    /// The model's history version, so that SwiftUI updates the list when it
    /// changes.
    let version: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.controller.scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.show(version)
    }

    final class Coordinator {
        let controller: CommitTableController
        private var shownVersion: Int?

        init(model: RepositoryModel) {
            controller = CommitTableController(source: CommitTableController.Source(
                count: { model.rowCount },
                content: { model.rowContent($0) },
                loadText: { await model.loadText(for: $0) }
            ))
        }

        func show(_ version: Int) {
            guard version != shownVersion else { return }
            shownVersion = version
            controller.reloadData()
        }
    }
}
