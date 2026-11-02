import CommitGraph
import GitRunner
import RepositoryEngine
import SwiftUI

/// One repository: for now, its history.
struct RepositoryView: View {
    let git: Git
    @State private var model: RepositoryModel

    init(path: String, git: Git) {
        self.git = git
        _model = State(initialValue: RepositoryModel(path: path))
    }

    var body: some View {
        content
            .navigationTitle(model.location?.name ?? (model.path as NSString).lastPathComponent)
            .navigationSubtitle(model.headDescription ?? "")
            .task(id: LoadRequest(sort: model.sort, reloads: model.reloads)) {
                await model.load(git: git)
            }
            .focusedSceneValue(\.repository, model)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .opening:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Show This Repository", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.reload() }
            }
        case .ready:
            HistoryPanel(model: model)
        }
    }

    private struct LoadRequest: Equatable {
        var sort: HistoryOrder.Sort
        var reloads: Int
    }
}

struct HistoryPanel: View {
    @Bindable var model: RepositoryModel

    var body: some View {
        Panel {
            Text("History")
                .font(.system(size: 13, weight: .medium))
                .padding(.leading, 4)
            if let history = model.history, history.isComplete {
                Text(history.rows.count == 1 ? "1 commit" : "\(history.rows.count.formatted()) commits")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        } trailing: {
            if let head = model.headDescription {
                Label(head, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.trailing, 6)
            }
            Menu {
                Picker("Order", selection: $model.sort) {
                    Text("Topological Order").tag(HistoryOrder.Sort.topological)
                    Text("Date Order").tag(HistoryOrder.Sort.date)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Order of History")
        } content: {
            if let history = model.history, history.isComplete, history.rows.isEmpty {
                ContentUnavailableView("No Commits Yet", systemImage: "clock", description: Text("Commits appear here once there are some."))
            } else {
                CommitList(model: model, version: model.historyVersion)
            }
        }
    }
}

extension FocusedValues {
    /// The repository in the focused window, for the menu commands.
    @Entry var repository: RepositoryModel?
}
